// Erzeugt das Settings-Icon: make_icon <pixel> <out.png>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
int main(int argc, char **argv) { @autoreleasepool {
    int px = atoi(argv[1]); CGFloat s = px;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, px, px, 8, 0, cs, kCGImageAlphaPremultipliedLast);
    CGPathRef r = CGPathCreateWithRoundedRect(CGRectMake(0, 0, s, s), s * 0.225, s * 0.225, NULL);
    CGContextAddPath(c, r); CGContextClip(c);
    CGFloat cols[] = {1.0, 0.80, 0.18, 1, 1.0, 0.58, 0.0, 1};
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, cols, NULL, 2);
    CGContextDrawLinearGradient(c, g, CGPointMake(0, s), CGPointMake(0, 0), 0);
    // Emoji
    CTFontRef f = CTFontCreateWithName(CFSTR("AppleColorEmoji"), s * 0.5, NULL);
    NSAttributedString *a = [[NSAttributedString alloc] initWithString:@"😀" attributes:@{(id)kCTFontAttributeName: (__bridge id)f}];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)a);
    CGContextSetTextPosition(c, s * 0.12, s * 0.33);
    CTLineDraw(line, c);
    // Lupe
    CGContextSetRGBStrokeColor(c, 1, 1, 1, 1);
    CGContextSetLineWidth(c, s * 0.075);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextStrokeEllipseInRect(c, CGRectMake(s * 0.47, s * 0.17, s * 0.33, s * 0.33));
    CGContextMoveToPoint(c, s * 0.76, s * 0.21);
    CGContextAddLineToPoint(c, s * 0.88, s * 0.09);
    CGContextStrokePath(c);
    CGImageRef img = CGBitmapContextCreateImage(c);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[2])], CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(d, img, NULL); CGImageDestinationFinalize(d);
    return 0;
}}
