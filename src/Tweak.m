// EmojiSearch12 – Emoji-Suche für die Stock-Tastatur unter iOS 12
//
// * Suchleiste oberhalb der Emoji-Liste (UIKeyboardEmojiCollectionInputView)
// * Tippen auf die Leiste öffnet ein Such-Panel über der Tastatur: Suchfeld,
//   Ergebnisreihe und eine kompakte Buchstabentastatur im Layout der aktiven Sprache
// * Suche komplett offline über CLDR-Stichwörter in der Tastatursprache
//   (+ Englisch als Fallback), nur Emojis, die der installierte Emoji-Font
//   (z. B. via EmojiPort) tatsächlich darstellen kann
//
// Keine Substrate-Abhängigkeit beim Linken: Hooks werden über die ObjC-Runtime gesetzt.

#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

#ifndef ES_DATA_DIR
#define ES_DATA_DIR @"/Library/Application Support/EmojiSearch12"
#endif

#pragma mark - Hook-Helfer

static void ESLogHookFail(SEL sel, const char *why);
static void ESHook(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls) { ESLogHookFail(sel, "Klasse fehlt"); return; }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { ESLogHookFail(sel, "Methode fehlt"); return; }
    IMP orig = method_getImplementation(m);
    // Für geerbte Methoden eine Überschreibung in der Klasse selbst anlegen,
    // damit die Oberklasse (z. B. UIView) unangetastet bleibt.
    if (class_addMethod(cls, sel, replacement, method_getTypeEncoding(m))) {
        *original = orig;
    } else {
        *original = method_setImplementation(m, replacement);
    }
}

#pragma mark - Logging
// NSLog (Console.app am Mac / oslog / syslog) und zusätzlich, wo die Sandbox es
// erlaubt (z. B. SpringBoard), in /var/mobile/Library/Logs/EmojiSearch12.log

#define ES_LOG_FILE @"/var/mobile/Library/Logs/EmojiSearch12.log"
#define ES_PREFS_DOMAIN "com.matthias.emojisearch12"
#define ES_PREFS_CHANGED "com.matthias.emojisearch12/prefs"

// Einstellung „Logging“ (Einstellungen → EmojiSearch12), Standard: aus
static BOOL gLogging;

static void ESLoadPrefs(void) {
    CFPreferencesAppSynchronize(CFSTR(ES_PREFS_DOMAIN));
    id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("logging"), CFSTR(ES_PREFS_DOMAIN)));
    if (!v) {
        // Fallback: Datei direkt lesen (falls cfprefsd in diesem Prozess nichts liefert)
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/" ES_PREFS_DOMAIN ".plist"];
        v = d[@"logging"];
    }
    gLogging = [v respondsToSelector:@selector(boolValue)] && [v boolValue];
}

static void ESLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void ESLog(NSString *fmt, ...) {
    if (!gLogging) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *proc = [NSProcessInfo processInfo].processName;
    NSLog(@"[EmojiSearch12] %@", msg);
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("emojisearch12.log", DISPATCH_QUEUE_SERIAL); });
    NSString *line = [NSString stringWithFormat:@"%@ %@[%d] %@\n", [NSDate date], proc, getpid(), msg];
    dispatch_async(q, ^{
        FILE *f = fopen(ES_LOG_FILE.fileSystemRepresentation, "a");
        if (!f) return;
        fputs(line.UTF8String, f);
        fclose(f);
    });
}

static void ESLogHookFail(SEL sel, const char *why) {
    // Fehler beim Setzen eines Hooks immer melden, unabhängig von der Einstellung
    NSLog(@"[EmojiSearch12] Hook %@ nicht gesetzt: %s", NSStringFromSelector(sel), why);
}

static void ESDumpTree(UIView *v, NSUInteger depth, NSMutableString *out) {
    if (!v || depth > 9) return;
    [out appendFormat:@"%@%@ %@%@\n", [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
        NSStringFromClass(v.class), NSStringFromCGRect(v.frame), v.hidden ? @" hidden" : @""];
    for (UIView *sub in v.subviews) ESDumpTree(sub, depth + 1, out);
}

static id ESMsg(id target, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (!target || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static id ESKeyboardImpl(void) {
    return ESMsg(NSClassFromString(@"UIKeyboardImpl"), @"activeInstance");
}

#pragma mark - Sprache / Layout

static NSString *gLastLanguage;   // z. B. "de-DE"
static NSString *gLastLayout;     // z. B. "QWERTZ"

static BOOL ESIsLinguisticMode(id mode) {
    NSString *lang = ESMsg(mode, @"primaryLanguage");
    if (![lang isKindOfClass:[NSString class]] || lang.length == 0) return NO;
    NSString *l = lang.lowercaseString;
    return !([l hasPrefix:@"emoji"] || [l hasPrefix:@"dictation"] || [l hasPrefix:@"autofill"]);
}

static void ESRememberMode(id mode) {
    if (!ESIsLinguisticMode(mode)) return;
    gLastLanguage = [ESMsg(mode, @"primaryLanguage") copy];
    NSString *layout = ESMsg(mode, @"softwareLayout");
    if (![layout isKindOfClass:[NSString class]]) {
        NSString *ident = ESMsg(mode, @"identifier");
        NSRange r = [ident isKindOfClass:[NSString class]] ? [ident rangeOfString:@"sw="] : NSMakeRange(NSNotFound, 0);
        if (r.location != NSNotFound) {
            layout = [ident substringFromIndex:NSMaxRange(r)];
            layout = [layout componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@";@"]].firstObject;
        }
    }
    gLastLayout = [layout isKindOfClass:[NSString class]] ? [layout copy] : nil;
}

static NSString *ESCurrentLanguage(void) {
    if (gLastLanguage) return gLastLanguage;
    id ctl = ESMsg(NSClassFromString(@"UIKeyboardInputModeController"), @"sharedInputModeController");
    for (NSString *s in @[@"currentLinguisticInputMode", @"lastUsedInputMode", @"currentInputMode"]) {
        id mode = ESMsg(ctl, s);
        if (ESIsLinguisticMode(mode)) { ESRememberMode(mode); return gLastLanguage; }
    }
    NSArray *modes = ESMsg(ctl, @"activeInputModes");
    if ([modes isKindOfClass:[NSArray class]]) {
        for (id mode in modes) if (ESIsLinguisticMode(mode)) { ESRememberMode(mode); return gLastLanguage; }
    }
    return [NSLocale preferredLanguages].firstObject ?: @"en";
}

static NSString *ESBaseLanguage(NSString *lang) {
    return [[lang stringByReplacingOccurrencesOfString:@"_" withString:@"-"] componentsSeparatedByString:@"-"].firstObject.lowercaseString ?: @"en";
}

#pragma mark - Lokalisierte UI-Texte

static NSString *ESText(NSString *key) {
    static NSDictionary *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @{
            @"de": @{@"search": @"Emoji suchen", @"none": @"Keine Emojis gefunden", @"space": @"Leerzeichen"},
            @"en": @{@"search": @"Search Emoji", @"none": @"No Emoji Found", @"space": @"space"},
            @"fr": @{@"search": @"Rechercher un emoji", @"none": @"Aucun emoji trouvé", @"space": @"espace"},
            @"es": @{@"search": @"Buscar emoji", @"none": @"No se encontraron emojis", @"space": @"espacio"},
            @"it": @{@"search": @"Cerca emoji", @"none": @"Nessuna emoji trovata", @"space": @"spazio"},
            @"pt": @{@"search": @"Buscar emoji", @"none": @"Nenhum emoji encontrado", @"space": @"espaço"},
            @"nl": @{@"search": @"Zoek emoji", @"none": @"Geen emoji gevonden", @"space": @"spatie"},
            @"sv": @{@"search": @"Sök emoji", @"none": @"Inga emojier hittades", @"space": @"mellanslag"},
            @"da": @{@"search": @"Søg efter emoji", @"none": @"Ingen emojis fundet", @"space": @"mellemrum"},
            @"nb": @{@"search": @"Søk etter emoji", @"none": @"Fant ingen emojier", @"space": @"mellomrom"},
            @"fi": @{@"search": @"Hae emojia", @"none": @"Emojeja ei löytynyt", @"space": @"välilyönti"},
            @"pl": @{@"search": @"Szukaj emoji", @"none": @"Nie znaleziono emoji", @"space": @"spacja"},
            @"cs": @{@"search": @"Hledat emoji", @"none": @"Žádné emoji nenalezeny", @"space": @"mezera"},
            @"tr": @{@"search": @"Emoji ara", @"none": @"Emoji bulunamadı", @"space": @"boşluk"},
            @"ru": @{@"search": @"Поиск эмодзи", @"none": @"Эмодзи не найдены", @"space": @"пробел"},
            @"uk": @{@"search": @"Пошук емодзі", @"none": @"Емодзі не знайдено", @"space": @"пробіл"},
            @"el": @{@"search": @"Αναζήτηση emoji", @"none": @"Δεν βρέθηκαν emoji", @"space": @"διάστημα"},
            @"ja": @{@"search": @"絵文字を検索", @"none": @"絵文字が見つかりません", @"space": @"空白"},
            @"zh": @{@"search": @"搜索表情符号", @"none": @"未找到表情符号", @"space": @"空格"},
            @"ko": @{@"search": @"이모티콘 검색", @"none": @"이모티콘 없음", @"space": @"스페이스"},
        };
    });
    NSString *base = ESBaseLanguage(ESCurrentLanguage());
    if ([base isEqualToString:@"no"] || [base isEqualToString:@"nn"]) base = @"nb";
    return t[base][key] ?: t[@"en"][key];
}

#pragma mark - Such-Engine

@interface ESEntry : NSObject
@property (nonatomic, copy) NSString *emoji;
@property (nonatomic, copy) NSString *name;       // gefaltet (klein, ohne Akzente)
@property (nonatomic, copy) NSArray<NSString *> *keywords;   // gefaltet
@property (nonatomic, copy) NSArray<NSString *> *words;      // einzelne Wörter aus Name + Stichwörtern
@property (nonatomic) NSUInteger order;
@end
@implementation ESEntry
@end

@interface ESEngine : NSObject
+ (instancetype)shared;
- (void)search:(NSString *)query language:(NSString *)language completion:(void (^)(NSArray<NSString *> *results))completion;
@end

@implementation ESEngine {
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, NSArray<ESEntry *> *> *_tables;
    NSMutableDictionary<NSString *, NSNumber *> *_renderable;
    NSSet<NSString *> *_available;
    NSUInteger _generation;
}

+ (instancetype)shared {
    static ESEngine *e;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ e = [ESEngine new]; });
    return e;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("emojisearch12.search", DISPATCH_QUEUE_SERIAL);
        _tables = [NSMutableDictionary new];
        _renderable = [NSMutableDictionary new];
        NSData *d = [NSData dataWithContentsOfFile:[ES_DATA_DIR stringByAppendingPathComponent:@"index.json"]];
        NSDictionary *idx = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSArray *locales = [idx isKindOfClass:[NSDictionary class]] ? idx[@"locales"] : nil;
        _available = [NSSet setWithArray:[locales isKindOfClass:[NSArray class]] ? locales : @[@"en"]];
    }
    return self;
}

static NSString *ESFold(NSString *s) {
    return [[s stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch
                                   locale:nil] lowercaseString];
}

// Sprachcode der Tastatur -> Datei in ES_DATA_DIR
- (NSString *)fileForLanguage:(NSString *)language {
    NSString *l = [language stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    NSString *lower = l.lowercaseString;
    NSMutableArray *cands = [NSMutableArray array];
    if ([lower hasPrefix:@"zh-hant-hk"] || [lower isEqualToString:@"zh-hk"]) [cands addObject:@"zh-Hant-HK"];
    if ([lower hasPrefix:@"zh-hant"] || [lower hasPrefix:@"zh-tw"] || [lower isEqualToString:@"zh-hk"]) [cands addObject:@"zh-Hant"];
    if ([lower hasPrefix:@"zh"]) [cands addObject:@"zh"];
    if ([lower hasPrefix:@"yue"]) [cands addObject:[lower containsString:@"hans"] ? @"yue-Hans" : @"yue"];
    if ([lower hasPrefix:@"nb"] || [lower hasPrefix:@"no"]) [cands addObject:@"no"];
    if ([lower hasPrefix:@"pt-pt"]) [cands addObject:@"pt-PT"];
    // de-CH, en-GB, es-MX, fr-CA … dann Basissprache
    NSArray *parts = [l componentsSeparatedByString:@"-"];
    for (NSInteger n = parts.count; n >= 1; n--) {
        [cands addObject:[[parts subarrayWithRange:NSMakeRange(0, n)] componentsJoinedByString:@"-"]];
    }
    if ([lower hasPrefix:@"en-"]) [cands addObject:@"en-001"];
    if ([lower hasPrefix:@"es-"]) [cands addObject:@"es-419"];
    for (NSString *c in cands) {
        // Groß-/Kleinschreibung der Region normalisieren (de-de -> de-DE)
        NSArray *p = [c componentsSeparatedByString:@"-"];
        NSMutableArray *norm = [NSMutableArray arrayWithObject:[p.firstObject lowercaseString]];
        for (NSUInteger i = 1; i < p.count; i++) {
            NSString *s = p[i];
            [norm addObject:s.length == 4 ? s.capitalizedString : (s.length == 2 ? s.uppercaseString : s)];
        }
        NSString *key = [norm componentsJoinedByString:@"-"];
        if ([_available containsObject:key]) return key;
    }
    return @"en";
}

- (NSArray<ESEntry *> *)tableForFile:(NSString *)file {
    NSArray *cached = _tables[file];
    if (cached) return cached;
    NSData *d = [NSData dataWithContentsOfFile:[ES_DATA_DIR stringByAppendingPathComponent:[file stringByAppendingPathExtension:@"json"]]];
    NSArray *rows = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows.count];
    NSCharacterSet *sep = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSUInteger i = 0;
    for (NSArray *row in [rows isKindOfClass:[NSArray class]] ? rows : @[]) {
        if (![row isKindOfClass:[NSArray class]] || row.count < 2) continue;
        ESEntry *e = [ESEntry new];
        e.emoji = row[0];
        e.name = ESFold(row[1]);
        NSMutableArray *kws = [NSMutableArray array];
        NSMutableSet *words = [NSMutableSet set];
        for (NSUInteger k = 1; k < row.count; k++) {
            NSString *f = ESFold(row[k]);
            if (k > 1) [kws addObject:f];
            for (NSString *w in [f componentsSeparatedByCharactersInSet:sep]) if (w.length) [words addObject:w];
        }
        e.keywords = kws;
        e.words = words.allObjects;
        e.order = i++;
        [out addObject:e];
    }
    _tables[file] = out;
    return out;
}

// Kann der installierte Emoji-Font (EmojiPort / neuere AppleColorEmoji) die Sequenz als ein Glyph darstellen?
- (BOOL)isRenderable:(NSString *)emoji {
    NSNumber *c = _renderable[emoji];
    if (c) return c.boolValue;
    static CTFontRef font;
    if (!font) font = CTFontCreateWithName(CFSTR("AppleColorEmoji"), 20, NULL);
    BOOL ok = NO;
    if (font) {
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:emoji attributes:@{(id)kCTFontAttributeName: (__bridge id)font}];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
        if (line) {
            CFArrayRef runs = CTLineGetGlyphRuns(line);
            if (CFArrayGetCount(runs) == 1) {
                CTRunRef run = CFArrayGetValueAtIndex(runs, 0);
                CTFontRef rf = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
                NSString *ps = rf ? CFBridgingRelease(CTFontCopyPostScriptName(rf)) : nil;
                CGGlyph g = 0;
                if (CTRunGetGlyphCount(run) == 1) CTRunGetGlyphs(run, CFRangeMake(0, 1), &g);
                ok = g != 0 && [ps hasPrefix:@"AppleColorEmoji"];
            }
            CFRelease(line);
        }
    } else {
        ok = YES;
    }
    _renderable[emoji] = @(ok);
    return ok;
}

static BOOL ESNeedsSubstring(NSString *q) {
    // Schriftsysteme ohne Wortzwischenräume (CJK, Thai …) oder lange Begriffe (dt. Komposita)
    if (q.length >= 3) return YES;
    unichar c = q.length ? [q characterAtIndex:0] : 0;
    return c >= 0x0E00;
}

- (void)collect:(NSArray<ESEntry *> *)table query:(NSString *)q tokens:(NSArray<NSString *> *)tokens
          bonus:(NSInteger)bonus into:(NSMutableDictionary<NSString *, NSNumber *> *)scores order:(NSMutableDictionary *)orders {
    BOOL substring = ESNeedsSubstring(q);
    for (ESEntry *e in table) {
        NSInteger score = NSIntegerMax;
        if ([e.name isEqualToString:q]) score = 0;
        else if ([e.keywords containsObject:q]) score = 1;
        else if ([e.name hasPrefix:q]) score = 2;
        else {
            for (NSString *k in e.keywords) if ([k hasPrefix:q]) { score = 3; break; }
            if (score == NSIntegerMax) {
                BOOL all = tokens.count > 0;
                for (NSString *t in tokens) {
                    BOOL hit = NO;
                    for (NSString *w in e.words) if ([w hasPrefix:t]) { hit = YES; break; }
                    if (!hit) { all = NO; break; }
                }
                if (all) score = 4;
            }
            if (score == NSIntegerMax && substring) {
                if ([e.name containsString:q]) score = 5;
                else for (NSString *k in e.keywords) if ([k containsString:q]) { score = 6; break; }
            }
        }
        if (score == NSIntegerMax) continue;
        score += bonus;
        NSNumber *old = scores[e.emoji];
        if (!old || old.integerValue > score) {
            scores[e.emoji] = @(score);
            if (!orders[e.emoji]) orders[e.emoji] = @(e.order);
        }
    }
}

- (void)search:(NSString *)query language:(NSString *)language completion:(void (^)(NSArray<NSString *> *))completion {
    NSUInteger gen = ++_generation;
    dispatch_async(_queue, ^{
        NSString *q = [ESFold(query) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSArray *results = @[];
        if (q.length) {
            NSMutableArray *tokens = [NSMutableArray array];
            for (NSString *t in [q componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) if (t.length) [tokens addObject:t];
            NSMutableDictionary *scores = [NSMutableDictionary dictionary], *orders = [NSMutableDictionary dictionary];
            NSString *file = [self fileForLanguage:language];
            [self collect:[self tableForFile:file] query:q tokens:tokens bonus:0 into:scores order:orders];
            if (![file isEqualToString:@"en"]) // Englisch als Fallback, niedriger gewichtet
                [self collect:[self tableForFile:@"en"] query:q tokens:tokens bonus:10 into:scores order:orders];
            NSArray *sorted = [scores.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                NSComparisonResult r = [scores[a] compare:scores[b]];
                return r != NSOrderedSame ? r : [orders[a] compare:orders[b]];
            }];
            NSMutableArray *filtered = [NSMutableArray array];
            for (NSString *e in sorted) {
                if ([self isRenderable:e]) [filtered addObject:e];
                if (filtered.count >= 120) break;
            }
            results = filtered;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen == self->_generation) completion(results);
        });
    });
}

@end

#pragma mark - Farben

@interface ESTheme : NSObject
@property (nonatomic) BOOL dark;
@end
@implementation ESTheme
+ (BOOL)isDark {
    id impl = ESKeyboardImpl();
    for (NSString *s in @[@"inputDelegate", @"delegate", @"delegateAsResponder"]) {
        id d = ESMsg(impl, s);
        if ([d respondsToSelector:@selector(keyboardAppearance)])
            return [(id<UITextInputTraits>)d keyboardAppearance] == UIKeyboardAppearanceDark;
    }
    return NO;
}
+ (UIColor *)background:(BOOL)dark { return dark ? [UIColor colorWithWhite:0.10 alpha:1] : [UIColor colorWithRed:0.82 green:0.835 blue:0.86 alpha:1]; }
+ (UIColor *)key:(BOOL)dark { return dark ? [UIColor colorWithWhite:0.36 alpha:1] : UIColor.whiteColor; }
+ (UIColor *)keyPressed:(BOOL)dark { return dark ? [UIColor colorWithWhite:0.22 alpha:1] : [UIColor colorWithRed:0.67 green:0.70 blue:0.74 alpha:1]; }
+ (UIColor *)specialKey:(BOOL)dark { return dark ? [UIColor colorWithWhite:0.22 alpha:1] : [UIColor colorWithRed:0.67 green:0.70 blue:0.74 alpha:1]; }
+ (UIColor *)text:(BOOL)dark { return dark ? UIColor.whiteColor : UIColor.blackColor; }
+ (UIColor *)field:(BOOL)dark { return dark ? [UIColor colorWithWhite:1 alpha:0.12] : [UIColor colorWithWhite:0 alpha:0.08]; }
+ (UIColor *)placeholder:(BOOL)dark { return dark ? [UIColor colorWithWhite:1 alpha:0.5] : [UIColor colorWithWhite:0 alpha:0.42]; }
@end

#pragma mark - Suchfeld

@interface ESMagnifier : UIView
@property (nonatomic, strong) UIColor *color;
@end
@implementation ESMagnifier
- (void)drawRect:(CGRect)rect {
    CGFloat s = MIN(rect.size.width, rect.size.height);
    UIBezierPath *p = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(1.5, 1.5, s * 0.62, s * 0.62)];
    [p moveToPoint:CGPointMake(s * 0.62, s * 0.62)];
    [p addLineToPoint:CGPointMake(s - 1.5, s - 1.5)];
    p.lineWidth = 1.8;
    p.lineCapStyle = kCGLineCapRound;
    [self.color setStroke];
    [p stroke];
}
@end

@interface ESSearchField : UIControl
@property (nonatomic, copy) NSString *text;
@property (nonatomic) BOOL active;
@property (nonatomic) BOOL dark;
@property (nonatomic, copy) void (^onClear)(void);
@end

@implementation ESSearchField {
    ESMagnifier *_icon;
    UILabel *_label;
    UIView *_caret;
    UIButton *_clear;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = 9;
        self.clipsToBounds = YES;
        _icon = [ESMagnifier new];
        _icon.backgroundColor = UIColor.clearColor;
        _icon.userInteractionEnabled = NO;
        [self addSubview:_icon];
        _label = [UILabel new];
        _label.font = [UIFont systemFontOfSize:16];
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];
        _caret = [UIView new];
        _caret.backgroundColor = [UIColor colorWithRed:0 green:0.48 blue:1 alpha:1];
        _caret.hidden = YES;
        [self addSubview:_caret];
        _clear = [UIButton buttonWithType:UIButtonTypeCustom];
        [_clear setTitle:@"✕" forState:UIControlStateNormal];
        _clear.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        _clear.layer.cornerRadius = 8;
        [_clear addTarget:self action:@selector(clearTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_clear];
        _text = @"";
        [self refresh];
    }
    return self;
}

- (void)clearTapped { if (self.onClear) self.onClear(); }

- (void)setText:(NSString *)text { _text = [text copy] ?: @""; [self refresh]; }
- (void)setActive:(BOOL)active { _active = active; [self refresh]; }
- (void)setDark:(BOOL)dark { _dark = dark; [self refresh]; }

- (void)refresh {
    self.backgroundColor = [ESTheme field:_dark];
    _icon.color = [ESTheme placeholder:_dark];
    [_icon setNeedsDisplay];
    BOOL empty = _text.length == 0;
    _label.text = empty ? ESText(@"search") : _text;
    _label.textColor = empty ? [ESTheme placeholder:_dark] : [ESTheme text:_dark];
    _clear.hidden = !_active || empty;
    _clear.backgroundColor = [ESTheme placeholder:_dark];
    [_clear setTitleColor:[ESTheme background:_dark] forState:UIControlStateNormal];
    [_caret.layer removeAllAnimations];
    _caret.hidden = !_active;
    if (_active) {
        CABasicAnimation *blink = [CABasicAnimation animationWithKeyPath:@"opacity"];
        blink.fromValue = @1; blink.toValue = @0;
        blink.duration = 0.5; blink.autoreverses = YES; blink.repeatCount = HUGE_VALF;
        blink.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        [_caret.layer addAnimation:blink forKey:@"blink"];
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height, w = self.bounds.size.width;
    _icon.frame = CGRectMake(8, (h - 14) / 2, 14, 14);
    CGFloat x = 28, clearW = _clear.hidden ? 0 : 24;
    CGSize ts = [_label sizeThatFits:CGSizeMake(w - x - clearW - 8, h)];
    BOOL empty = _text.length == 0;
    CGFloat labelW = MIN(ts.width, w - x - clearW - 10);
    if (empty && _active) {
        // Placeholder hinter dem Cursor, wie bei iOS
        _caret.frame = CGRectMake(x, (h - 18) / 2, 2, 18);
        _label.frame = CGRectMake(x + 3, 0, labelW, h);
    } else {
        _label.frame = CGRectMake(x, 0, labelW, h);
        _caret.frame = CGRectMake(x + labelW + 1, (h - 18) / 2, 2, 18);
    }
    _clear.frame = CGRectMake(w - 24, (h - 16) / 2, 16, 16);
}

@end

#pragma mark - Kompakte Tastatur

typedef NS_ENUM(NSInteger, ESKeyKind) { ESKeyChar, ESKeyDelete, ESKeySpace, ESKeyBack, ESKeyGlobe };

@interface ESKey : UIButton
@property (nonatomic) ESKeyKind kind;
@property (nonatomic, copy) NSString *value;
@property (nonatomic) CGFloat units;
@end
@implementation ESKey
@end

static NSArray<NSString *> *ESRowsForLayout(NSString *lang, NSString *layout, BOOL forceLatin) {
    NSString *b = ESBaseLanguage(lang);
    NSString *sw = layout.uppercaseString ?: @"";
    if (!forceLatin) {
        if ([b isEqualToString:@"ru"] || [b isEqualToString:@"be"] || [b isEqualToString:@"kk"] || [b isEqualToString:@"bg"] || [b isEqualToString:@"sr"] || [b isEqualToString:@"mk"]) {
            if (![sw containsString:@"QWERT"] && ![sw containsString:@"LATIN"])
                return @[@"йцукенгшщзх", @"фывапролджэ", @"ячсмитьбю"];
        }
        if ([b isEqualToString:@"uk"]) return @[@"йцукенгшщзхї", @"фівапролджє", @"ячсмитьбю"];
        if ([b isEqualToString:@"el"]) return @[@"ςερτυθιοπ", @"ασδφγηξκλ", @"ζχψωβνμ"];
        if ([b isEqualToString:@"he"]) return @[@"קראטוןםפ", @"שדגכעיחלךף", @"זסבהנמצתץ"];
        if ([b isEqualToString:@"ar"] || [b isEqualToString:@"fa"] || [b isEqualToString:@"ur"])
            return @[@"ضصثقفغعهخحج", @"شسيبلاتنمكط", @"ئءؤرىةوزظد"];
    }
    if (forceLatin) return @[@"qwertyuiop", @"asdfghjkl", @"zxcvbnm"];
    if ([sw containsString:@"AZERTY"] || (sw.length == 0 && [b isEqualToString:@"fr"]))
        return @[@"azertyuiop", @"qsdfghjklm", @"wxcvbn"];
    if ([sw containsString:@"QWERTZ"] || (sw.length == 0 && ([b isEqualToString:@"de"] || [b isEqualToString:@"cs"] || [b isEqualToString:@"sk"] || [b isEqualToString:@"hu"]))) {
        if ([b isEqualToString:@"de"] || [b isEqualToString:@"gsw"] || [b isEqualToString:@"lb"])
            return @[@"qwertzuiopü", @"asdfghjklöä", @"yxcvbnmß"];
        return @[@"qwertzuiop", @"asdfghjkl", @"yxcvbnm"];
    }
    if ([b isEqualToString:@"es"] || [b isEqualToString:@"gl"]) return @[@"qwertyuiop", @"asdfghjklñ", @"zxcvbnm"];
    if ([b isEqualToString:@"sv"] || [b isEqualToString:@"fi"] || [b isEqualToString:@"et"]) return @[@"qwertyuiopå", @"asdfghjklöä", @"zxcvbnm"];
    if ([b isEqualToString:@"da"] || [b isEqualToString:@"nb"] || [b isEqualToString:@"no"] || [b isEqualToString:@"nn"]) return @[@"qwertyuiopå", @"asdfghjklæø", @"zxcvbnm"];
    if ([b isEqualToString:@"tr"]) return @[@"qwertyuıopğü", @"asdfghjklşi", @"zxcvbnmöç"];
    return @[@"qwertyuiop", @"asdfghjkl", @"zxcvbnm"];
}

static BOOL ESLayoutIsNonLatin(NSArray<NSString *> *rows) {
    unichar c = [rows.firstObject characterAtIndex:0];
    return c >= 0x0370;
}

#pragma mark - Such-Panel

@interface ESSearchPanel : UIView
+ (instancetype)current;
+ (void)presentInKeyboardView:(UIView *)host;
+ (void)dismiss;
@end

static __weak ESSearchPanel *gPanel;

@implementation ESSearchPanel {
    BOOL _dark;
    BOOL _latin;
    ESSearchField *_field;
    UIScrollView *_results;
    UILabel *_emptyLabel;
    UIView *_keyboard;
    NSMutableArray<NSArray<ESKey *> *> *_rows;
    NSString *_query;
    NSTimer *_repeat;
    NSArray<NSString *> *_resultEmojis;
}

+ (instancetype)current { return gPanel.superview ? gPanel : nil; }

+ (void)presentInKeyboardView:(UIView *)host {
    if (!host) return;
    [self dismiss];
    ESSearchPanel *p = [[ESSearchPanel alloc] initWithFrame:host.bounds];
    p.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:p];
    gPanel = p;
}

+ (void)dismiss {
    ESSearchPanel *p = gPanel;
    if (!p) return;   // Ivar-Zugriff über nil (p->_repeat) würde crashen
    [p->_repeat invalidate];
    [p removeFromSuperview];
    gPanel = nil;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _dark = [ESTheme isDark];
        _query = @"";
        self.backgroundColor = [ESTheme background:_dark];
        self.multipleTouchEnabled = YES;
        self.exclusiveTouch = NO;

        _field = [ESSearchField new];
        _field.dark = _dark;
        _field.active = YES;
        __weak typeof(self) ws = self;
        _field.onClear = ^{ [ws setQuery:@""]; };
        [self addSubview:_field];

        _results = [UIScrollView new];
        _results.showsHorizontalScrollIndicator = NO;
        _results.alwaysBounceHorizontal = YES;
        [self addSubview:_results];

        _emptyLabel = [UILabel new];
        _emptyLabel.font = [UIFont systemFontOfSize:14];
        _emptyLabel.textColor = [ESTheme placeholder:_dark];
        _emptyLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_emptyLabel];

        _keyboard = [UIView new];
        [self addSubview:_keyboard];
        [self buildKeys];
    }
    return self;
}

- (ESKey *)keyWithTitle:(NSString *)title kind:(ESKeyKind)kind value:(NSString *)value units:(CGFloat)units {
    ESKey *k = [ESKey buttonWithType:UIButtonTypeCustom];
    k.kind = kind;
    k.value = value;
    k.units = units;
    BOOL special = kind != ESKeyChar && kind != ESKeySpace;
    [k setTitle:title forState:UIControlStateNormal];
    [k setTitleColor:[ESTheme text:_dark] forState:UIControlStateNormal];
    k.titleLabel.font = kind == ESKeyChar ? [UIFont systemFontOfSize:20] : [UIFont systemFontOfSize:kind == ESKeySpace ? 14 : 18];
    k.backgroundColor = special ? [ESTheme specialKey:_dark] : [ESTheme key:_dark];
    k.layer.cornerRadius = 5;
    k.layer.shadowColor = UIColor.blackColor.CGColor;
    k.layer.shadowOpacity = 0.3;
    k.layer.shadowRadius = 0;
    k.layer.shadowOffset = CGSizeMake(0, 1);
    [k addTarget:self action:@selector(keyDown:) forControlEvents:UIControlEventTouchDown];
    [k addTarget:self action:@selector(keyUp:) forControlEvents:UIControlEventTouchUpInside];
    [k addTarget:self action:@selector(keyCancel:) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    return k;
}

- (void)buildKeys {
    for (UIView *v in _keyboard.subviews.copy) [v removeFromSuperview];
    _rows = [NSMutableArray array];
    NSArray<NSString *> *letters = ESRowsForLayout(ESCurrentLanguage(), gLastLayout, _latin);
    BOOL needsGlobe = _latin || ESLayoutIsNonLatin(letters);
    for (NSUInteger r = 0; r < letters.count; r++) {
        NSMutableArray *row = [NSMutableArray array];
        NSString *s = letters[r];
        [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                           usingBlock:^(NSString *ch, NSRange a, NSRange b, BOOL *stop) {
            [row addObject:[self keyWithTitle:ch kind:ESKeyChar value:ch units:1]];
        }];
        if (r == letters.count - 1) [row addObject:[self keyWithTitle:@"⌫" kind:ESKeyDelete value:nil units:1.5]];
        [_rows addObject:row];
    }
    NSMutableArray *bottom = [NSMutableArray array];
    [bottom addObject:[self keyWithTitle:@"☺︎" kind:ESKeyBack value:nil units:1.5]];
    if (needsGlobe) [bottom addObject:[self keyWithTitle:_latin ? @"🌐" : @"ABC" kind:ESKeyGlobe value:nil units:1.5]];
    [bottom addObject:[self keyWithTitle:ESText(@"space") kind:ESKeySpace value:@" " units:6]];
    [_rows addObject:bottom];
    for (NSArray *row in _rows) for (ESKey *k in row) [_keyboard addSubview:k];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat w = b.size.width, h = b.size.height;
    CGFloat fieldH = MIN(36, MAX(28, h * 0.16));
    CGFloat resultsH = MIN(46, MAX(32, h * 0.2));
    CGFloat side = 6;
    _field.frame = CGRectMake(side + 2, 5, w - 2 * side - 4, fieldH - 6);
    _results.frame = CGRectMake(0, fieldH, w, resultsH);
    _emptyLabel.frame = _results.frame;
    _keyboard.frame = CGRectMake(0, fieldH + resultsH, w, h - fieldH - resultsH);
    [self layoutResults];

    // Tasten: alle Reihen am breitesten Buchstabenblock ausrichten
    CGFloat kh = _keyboard.bounds.size.height;
    NSUInteger rowCount = _rows.count;
    CGFloat vGap = 6, hGap = 5;
    CGFloat rowH = floor((kh - vGap * (rowCount + 0.5)) / rowCount);
    CGFloat maxUnits = 0;
    for (NSUInteger r = 0; r + 1 < rowCount; r++) {
        CGFloat u = 0; for (ESKey *k in _rows[r]) u += k.units;
        maxUnits = MAX(maxUnits, u);
    }
    CGFloat unitW = (w - 2 * side - hGap * (maxUnits - 1)) / maxUnits;
    CGFloat y = vGap * 0.5;
    for (NSUInteger r = 0; r < rowCount; r++) {
        NSArray<ESKey *> *row = _rows[r];
        BOOL last = r == rowCount - 1;
        CGFloat units = 0; for (ESKey *k in row) units += k.units;
        CGFloat rowW = units * unitW + (row.count - 1) * hGap;
        CGFloat scale = 1;
        if (last || rowW > w - 2 * side) { scale = (w - 2 * side - (row.count - 1) * hGap) / (units * unitW); rowW = w - 2 * side; }
        CGFloat x = (w - rowW) / 2;
        for (ESKey *k in row) {
            CGFloat kw = k.units * unitW * scale + (k.units > 1 && !last ? 0 : 0);
            k.frame = CGRectIntegral(CGRectMake(x, y, kw, rowH));
            x += kw + hGap;
        }
        y += rowH + vGap;
    }
}

- (void)layoutResults {
    CGFloat h = _results.bounds.size.height;
    CGFloat cell = h;
    NSUInteger i = 0;
    for (UIView *v in _results.subviews) {
        if (![v isKindOfClass:[UIButton class]]) continue;
        v.frame = CGRectMake(6 + i * cell, 0, cell, h);
        i++;
    }
    _results.contentSize = CGSizeMake(12 + i * cell, h);
}

#pragma mark Tasten

- (void)keyDown:(ESKey *)k {
    k.backgroundColor = [ESTheme keyPressed:_dark];
    if (k.kind == ESKeyDelete) {
        [self deleteBackward];
        [_repeat invalidate];
        __weak typeof(self) ws = self;
        _repeat = [NSTimer scheduledTimerWithTimeInterval:0.45 repeats:NO block:^(NSTimer *t) {
            typeof(self) ss = ws;
            if (!ss) return;
            ss->_repeat = [NSTimer scheduledTimerWithTimeInterval:0.09 repeats:YES block:^(NSTimer *t2) { [ws deleteBackward]; }];
        }];
    }
}

- (void)keyCancel:(ESKey *)k {
    [_repeat invalidate]; _repeat = nil;
    BOOL special = k.kind != ESKeyChar && k.kind != ESKeySpace;
    k.backgroundColor = special ? [ESTheme specialKey:_dark] : [ESTheme key:_dark];
}

- (void)keyUp:(ESKey *)k {
    [self keyCancel:k];
    switch (k.kind) {
        case ESKeyChar:
        case ESKeySpace:
            if (k.kind == ESKeySpace && (_query.length == 0 || [_query hasSuffix:@" "])) return;
            [self setQuery:[_query stringByAppendingString:k.value]];
            break;
        case ESKeyDelete: break;
        case ESKeyBack: [ESSearchPanel dismiss]; break;
        case ESKeyGlobe: _latin = !_latin; [self buildKeys]; break;
    }
}

- (void)deleteBackward {
    if (!_query.length) return;
    NSRange r = [_query rangeOfComposedCharacterSequenceAtIndex:_query.length - 1];
    [self setQuery:[_query substringToIndex:r.location]];
}

#pragma mark Suche

- (void)setQuery:(NSString *)q {
    _query = [q copy];
    _field.text = q;
    if (!q.length) { [self showResults:@[]]; return; }
    __weak typeof(self) ws = self;
    [[ESEngine shared] search:q language:ESCurrentLanguage() completion:^(NSArray<NSString *> *results) {
        [ws showResults:results];
    }];
}

- (void)showResults:(NSArray<NSString *> *)results {
    _resultEmojis = results;
    for (UIView *v in _results.subviews.copy) if ([v isKindOfClass:[UIButton class]]) [v removeFromSuperview];
    CGFloat fontSize = MAX(22, MIN(32, _results.bounds.size.height * 0.68));
    NSInteger tag = 0;
    for (NSString *e in results) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        [b setTitle:e forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:fontSize];
        b.tag = tag++;
        [b addTarget:self action:@selector(emojiTapped:) forControlEvents:UIControlEventTouchUpInside];
        [b addTarget:self action:@selector(emojiDown:) forControlEvents:UIControlEventTouchDown];
        [b addTarget:self action:@selector(emojiUp:) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchUpInside];
        b.layer.cornerRadius = 6;
        [_results addSubview:b];
    }
    _results.contentOffset = CGPointZero;
    _emptyLabel.text = (_query.length && !results.count) ? ESText(@"none") : nil;
    [self layoutResults];
}

- (void)emojiDown:(UIButton *)b { b.backgroundColor = [ESTheme field:_dark]; }
- (void)emojiUp:(UIButton *)b { b.backgroundColor = UIColor.clearColor; }

- (void)emojiTapped:(UIButton *)b {
    NSString *emoji = [b titleForState:UIControlStateNormal];
    if (!emoji.length) return;
    id impl = ESKeyboardImpl();
    if ([impl respondsToSelector:@selector(insertText:)]) {
        [impl insertText:emoji];
    }
}

@end

#pragma mark - Suchleiste in der Emoji-Tastatur

static const void *kESBarKey = &kESBarKey;
static NSHashTable<UIView *> *gBars;

@interface ESEmojiBar : UIView
@property (nonatomic, strong) ESSearchField *field;
@end
@implementation ESEmojiBar
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _field = [ESSearchField new];
        [_field addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_field];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _field.frame = CGRectInset(self.bounds, 8, 4);
}
- (void)open {
    // Panel über die gesamte Tastatur legen (UIKeyboard), damit genug Platz
    // für Suchfeld + Ergebnisse + Buchstaben bleibt.
    UIView *host = self.superview;
    Class kb = NSClassFromString(@"UIKeyboard");
    for (UIView *v = self.superview; v; v = v.superview) {
        if (kb && [v isKindOfClass:kb]) { host = v; break; }
    }
    [ESSearchPanel presentInKeyboardView:host];
}
@end

static UIView *ESCollectionViewOf(UIView *inputView) {
    Ivar iv = class_getInstanceVariable(object_getClass(inputView), "_collectionView");
    id cv = iv ? object_getIvar(inputView, iv) : nil;
    if ([cv isKindOfClass:[UICollectionView class]]) return cv;
    for (UIView *v in inputView.subviews) if ([v isKindOfClass:[UICollectionView class]]) return v;
    return nil;
}

static void ESInstallBar(UIView *self, NSString *reason) {
    UIView *cv = ESCollectionViewOf(self);
    static NSUInteger logCount;
    BOOL verbose = logCount < 6;
    if (!cv) {
        if (verbose) { logCount++; ESLog(@"%@: keine Collection-View in %@ gefunden", reason, self); }
        return;
    }
    const CGFloat barH = 40;
    ESEmojiBar *bar = objc_getAssociatedObject(self, kESBarKey);
    if (!bar) {
        bar = [ESEmojiBar new];
        objc_setAssociatedObject(self, kESBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gBars) gBars = [NSHashTable weakObjectsHashTable];
        [gBars addObject:bar];
    }
    if (bar.superview != self) [self addSubview:bar];
    // Collection-View um die Höhe der Leiste nach unten verschieben – nur solange
    // sie noch oben anliegt, damit wiederholte Layout-Durchläufe nicht doppelt schieben.
    CGRect before = cv.frame, f = before;
    if (f.origin.y < barH - 1 && f.size.height > barH * 2.5) {
        f.origin.y += barH;
        f.size.height -= barH;
        cv.frame = f;
        [((UICollectionView *)cv).collectionViewLayout invalidateLayout];
    }
    bar.frame = CGRectMake(cv.frame.origin.x, cv.frame.origin.y - barH, cv.frame.size.width, barH);
    bar.field.dark = [ESTheme isDark];
    [self bringSubviewToFront:bar];
    if (verbose) {
        logCount++;
        ESLog(@"%@: view=%@ bounds=%@ cv %@ -> %@ bar=%@ window=%@", reason, NSStringFromClass(self.class),
              NSStringFromCGRect(self.bounds), NSStringFromCGRect(before), NSStringFromCGRect(cv.frame),
              NSStringFromCGRect(bar.frame), self.window ? NSStringFromClass(self.window.class) : @"nil");
    }
}

static void (*orig_emoji_layoutSubviews)(UIView *, SEL);
static void hook_emoji_layoutSubviews(UIView *self, SEL _cmd) {
    orig_emoji_layoutSubviews(self, _cmd);
    ESInstallBar(self, @"layoutSubviews");
}

static void (*orig_emoji_didMoveToWindow)(UIView *, SEL);
static void hook_emoji_didMoveToWindow(UIView *self, SEL _cmd) {
    orig_emoji_didMoveToWindow(self, _cmd);
    if (!self.window) { [ESSearchPanel dismiss]; return; }
    ESInstallBar(self, @"didMoveToWindow");
    __weak UIView *ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *v = ws;
        if (!v.window) return;
        ESInstallBar(v, @"didMoveToWindow+async");
        static BOOL dumped;
        if (!dumped) {
            dumped = YES;
            UIView *top = v;
            while (top.superview) top = top.superview;
            NSMutableString *tree = [NSMutableString string];
            ESDumpTree(top, 0, tree);
            ESLog(@"View-Hierarchie der Tastatur:\n%@", tree);
        }
    });
}

#pragma mark - Touch-Routing
// Die Keyboard-Layouts verteilen Touches selbst (subTreeHitTest:). Damit unsere
// Leiste und das Panel echte Touches bekommen, fangen wir hitTest: ganz oben ab.

static BOOL ESIsVisible(UIView *v) {
    for (; v; v = v.superview) if (v.hidden || v.alpha < 0.01) return NO;
    return YES;
}

static UIView *ESInterceptHit(UIView *receiver, CGPoint p, UIEvent *event) {
    ESSearchPanel *panel = [ESSearchPanel current];
    if (panel && panel.window == receiver.window && ESIsVisible(panel)) {
        CGPoint lp = [receiver convertPoint:p toView:panel];
        if ([panel pointInside:lp withEvent:event]) return [panel hitTest:lp withEvent:event] ?: panel;
    }
    for (ESEmojiBar *bar in gBars) {
        if (!bar.window || bar.window != receiver.window || !ESIsVisible(bar)) continue;
        CGPoint lp = [receiver convertPoint:p toView:bar];
        if ([bar pointInside:lp withEvent:event]) return [bar hitTest:lp withEvent:event] ?: bar.field;
    }
    return nil;
}

static UIView *(*orig_window_hitTest)(UIView *, SEL, CGPoint, UIEvent *);
static UIView *hook_window_hitTest(UIView *self, SEL _cmd, CGPoint p, UIEvent *event) {
    UIView *v = ESInterceptHit(self, p, event);
    return v ?: orig_window_hitTest(self, _cmd, p, event);
}

static UIView *(*orig_host_hitTest)(UIView *, SEL, CGPoint, UIEvent *);
static UIView *hook_host_hitTest(UIView *self, SEL _cmd, CGPoint p, UIEvent *event) {
    UIView *v = ESInterceptHit(self, p, event);
    return v ?: orig_host_hitTest(self, _cmd, p, event);
}

#pragma mark - Eingabemodus verfolgen

static void (*orig_setCurrentInputMode)(id, SEL, id);
static void hook_setCurrentInputMode(id self, SEL _cmd, id mode) {
    orig_setCurrentInputMode(self, _cmd, mode);
    ESLog(@"Eingabemodus: %@ (%@)", ESMsg(mode, @"identifier"), ESMsg(mode, @"primaryLanguage"));
    ESRememberMode(mode);
    if (!ESIsLinguisticMode(mode)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            static NSUInteger dumps;
            if (dumps >= 2) return;
            dumps++;
            UIView *kb = ESMsg(NSClassFromString(@"UIKeyboard"), @"activeKeyboard");
            UIView *top = kb;
            while (top.superview) top = top.superview;
            NSMutableString *tree = [NSMutableString string];
            ESDumpTree(top, 0, tree);
            ESLog(@"Nicht-Sprach-Modus aktiv, Tastatur-Hierarchie:\n%@", tree.length ? tree : @"(keine UIKeyboard gefunden)");
        });
    }
    if (!ESIsLinguisticMode(mode)) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [ESSearchPanel dismiss]; });
}

#pragma mark - Init

__attribute__((constructor)) static void ESInit(void) {
    @autoreleasepool {
        ESLoadPrefs();
        int token;
        notify_register_dispatch(ES_PREFS_CHANGED, &token, dispatch_get_main_queue(), ^(int t) {
            BOOL was = gLogging;
            ESLoadPrefs();
            if (gLogging && !was) ESLog(@"Logging eingeschaltet in %@", [NSProcessInfo processInfo].processName);
        });
        ESLog(@"geladen in %@ (%@), iOS %@", [NSProcessInfo processInfo].processName,
              [NSBundle mainBundle].bundleIdentifier, [UIDevice currentDevice].systemVersion);
        Class emoji = NSClassFromString(@"UIKeyboardEmojiCollectionInputView");
        if (!emoji) { ESLog(@"UIKeyboardEmojiCollectionInputView nicht gefunden – keine Hooks"); return; }
        ESHook(emoji, @selector(layoutSubviews), (IMP)hook_emoji_layoutSubviews, (IMP *)&orig_emoji_layoutSubviews);
        ESHook(emoji, @selector(didMoveToWindow), (IMP)hook_emoji_didMoveToWindow, (IMP *)&orig_emoji_didMoveToWindow);
        ESHook(NSClassFromString(@"UITextEffectsWindow"), @selector(hitTest:withEvent:), (IMP)hook_window_hitTest, (IMP *)&orig_window_hitTest);
        ESHook(NSClassFromString(@"UIInputSetHostView"), @selector(hitTest:withEvent:), (IMP)hook_host_hitTest, (IMP *)&orig_host_hitTest);
        ESHook(NSClassFromString(@"UIKeyboardInputModeController"), @selector(setCurrentInputMode:), (IMP)hook_setCurrentInputMode, (IMP *)&orig_setCurrentInputMode);
        ESLog(@"Hooks: layout=%d window=%d winHit=%d hostHit=%d mode=%d", orig_emoji_layoutSubviews != NULL,
              orig_emoji_didMoveToWindow != NULL, orig_window_hitTest != NULL, orig_host_hitTest != NULL, orig_setCurrentInputMode != NULL);
    }
}
