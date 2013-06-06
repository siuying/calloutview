#import "SMCalloutView.h"
#import <QuartzCore/QuartzCore.h>

//
// UIView frame helpers - we do a lot of UIView frame fiddling in this class; these functions help keep things readable.
//

@interface UIView (SMFrameAdditions)
@property (nonatomic, assign) CGPoint $origin;
@property (nonatomic, assign) CGSize $size;
@property (nonatomic, assign) CGFloat $x, $y, $width, $height; // normal rect properties
@property (nonatomic, assign) CGFloat $left, $top, $right, $bottom; // these will stretch/shrink the rect
@end

//
// Callout View.
//

NSTimeInterval kSMCalloutViewRepositionDelayForUIScrollView = 1.0/3.0;

#define CALLOUT_DEFAULT_MIN_WIDTH 75 // our image-based background graphics limit us to this minimum width...
#define CALLOUT_DEFAULT_HEIGHT 70 // ...and allow only for this exact height.
#define CALLOUT_DEFAULT_WIDTH 153 // default "I give up" width when we are asked to present in a space less than our min width
#define TITLE_MARGIN 17 // the title view's normal horizontal margin from the edges of our callout view
#define TITLE_TOP 11 // the top of the title view when no subtitle is present
#define TITLE_SUB_TOP 3 // the top of the title view when a subtitle IS present
#define TITLE_HEIGHT 22 // title height, fixed
#define SUBTITLE_TOP 25 // the top of the subtitle, when present
#define SUBTITLE_HEIGHT 16 // subtitle height, fixed
#define TITLE_ACCESSORY_MARGIN 6 // the margin between the title and an accessory if one is present (on either side)
#define ACCESSORY_MARGIN 14 // the accessory's margin from the edges of our callout view
#define ACCESSORY_TOP 8 // the top of the accessory "area" in which accessory views are placed
#define ACCESSORY_HEIGHT 32 // the "suggested" maximum height of an accessory view. shorter accessories will be vertically centered
#define BETWEEN_ACCESSORIES_MARGIN 7 // if we have no title or subtitle, but have two accessory views, then this is the space between them
#define ANCHOR_MARGIN 37 // the smallest possible distance from the edge of our control to the "tip" of the anchor, from either left or right
#define TOP_ANCHOR_MARGIN 13 // all the above measurements assume a bottom anchor! if we're pointing "up" we'll need to add this top margin to everything.
#define BOTTOM_ANCHOR_MARGIN 10 // if using a bottom anchor, we'll need to account for the shadow below the "tip"
#define REPOSITION_MARGIN 10 // when we try to reposition content to be visible, we'll consider this margin around your target rect

#define TOP_SHADOW_BUFFER 2 // height offset buffer to account for top shadow
#define BOTTOM_SHADOW_BUFFER 5 // height offset buffer to account for bottom shadow
#define OFFSET_FROM_ORIGIN 5 // distance to offset vertically from the rect origin of the callout
#define ANCHOR_HEIGHT 14 // height to use for the anchor
#define ANCHOR_MARGIN_MIN 24 // the smallest possible distance from the edge of our control to the edge of the anchor, from either left or right

@implementation SMCalloutView {
    UILabel *titleLabel, *subtitleLabel;
    UIImageView *leftCap, *rightCap, *topAnchor, *bottomAnchor, *leftBackground, *rightBackground;
    SMCalloutArrowDirection arrowDirection;
    BOOL popupCancelled;
}

- (id)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        _presentAnimation = SMCalloutAnimationBounce;
        _dismissAnimation = SMCalloutAnimationFade;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (UIView *)titleViewOrDefault {
    if (self.titleView)
        // if you have a custom title view defined, return that.
        return self.titleView;
    else {
        if (!titleLabel) {
            // create a default titleView
            titleLabel = [UILabel new];
            titleLabel.$height = TITLE_HEIGHT;
            titleLabel.opaque = NO;
            titleLabel.backgroundColor = [UIColor clearColor];
            titleLabel.font = [UIFont boldSystemFontOfSize:17];
            titleLabel.textColor = [UIColor whiteColor];
            titleLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.5];
            titleLabel.shadowOffset = CGSizeMake(0, -1);
        }
        return titleLabel;
    }
}

- (UIView *)subtitleViewOrDefault {
    if (self.subtitleView)
        // if you have a custom subtitle view defined, return that.
        return self.subtitleView;
    else {
        if (!subtitleLabel) {
            // create a default subtitleView
            subtitleLabel = [UILabel new];
            subtitleLabel.$height = SUBTITLE_HEIGHT;
            subtitleLabel.opaque = NO;
            subtitleLabel.backgroundColor = [UIColor clearColor];
            subtitleLabel.font = [UIFont systemFontOfSize:12];
            subtitleLabel.textColor = [UIColor whiteColor];
            subtitleLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.5];
            subtitleLabel.shadowOffset = CGSizeMake(0, -1);
        }
        return subtitleLabel;
    }
}

- (SMCalloutBackgroundView *)backgroundView {
    // create our default background on first access only if it's nil, since you might have set your own background anyway.
    return _backgroundView ?: (_backgroundView = [SMCalloutDrawnBackgroundView new]);
}

- (void)rebuildSubviews {
    // remove and re-add our appropriate subviews in the appropriate order
    [self.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    [self setNeedsDisplay];
    
    [self addSubview:self.backgroundView];
    
    if (self.contentView) {
        [self addSubview:self.contentView];
    }
    else {
        if (self.titleViewOrDefault) [self addSubview:self.titleViewOrDefault];
        if (self.subtitleViewOrDefault) [self addSubview:self.subtitleViewOrDefault];
    }
    if (self.leftAccessoryView) [self addSubview:self.leftAccessoryView];
    if (self.rightAccessoryView) [self addSubview:self.rightAccessoryView];
}

- (CGFloat)innerContentMarginLeft {
    if (self.leftAccessoryView)
        return ACCESSORY_MARGIN + self.leftAccessoryView.$width + TITLE_ACCESSORY_MARGIN;
    else
        return TITLE_MARGIN;
}

- (CGFloat)innerContentMarginRight {
    if (self.rightAccessoryView)
        return ACCESSORY_MARGIN + self.rightAccessoryView.$width + TITLE_ACCESSORY_MARGIN;
    else
        return TITLE_MARGIN;
}

- (CGFloat)calloutHeight {
    if (self.contentView)
        return self.contentView.$height + TITLE_TOP*2 + ANCHOR_HEIGHT + BOTTOM_ANCHOR_MARGIN;
    else
        return CALLOUT_DEFAULT_HEIGHT;
}

- (CGSize)sizeThatFits:(CGSize)size {
    
    // odd behavior, but mimicking the system callout view
    if (size.width < CALLOUT_DEFAULT_MIN_WIDTH)
        return CGSizeMake(CALLOUT_DEFAULT_WIDTH, self.calloutHeight);
    
    // calculate how much non-negotiable space we need to reserve for margin and accessories
    CGFloat margin = self.innerContentMarginLeft + self.innerContentMarginRight;
    
    // how much room is left for text?
    CGFloat availableWidthForText = size.width - margin;

    // no room for text? then we'll have to squeeze into the given size somehow.
    if (availableWidthForText < 0)
        availableWidthForText = 0;

    CGSize preferredTitleSize = [self.titleViewOrDefault sizeThatFits:CGSizeMake(availableWidthForText, TITLE_HEIGHT)];
    CGSize preferredSubtitleSize = [self.subtitleViewOrDefault sizeThatFits:CGSizeMake(availableWidthForText, SUBTITLE_HEIGHT)];
    
    // total width we'd like
    CGFloat preferredWidth;
    
    if (self.contentView) {
        
        // if we have a content view, then take our preferred size directly from that
        preferredWidth = self.contentView.$width + margin;
    }
    else if (preferredTitleSize.width >= 0.000001 || preferredSubtitleSize.width >= 0.000001) {
        
        // if we have a title or subtitle, then our assumed margins are valid, and we can apply them
        preferredWidth = fmaxf(preferredTitleSize.width, preferredSubtitleSize.width) + margin;
    }
    else {
        // ok we have no title or subtitle to speak of. In this case, the system callout would actually not display
        // at all! But we can handle it.
        preferredWidth = self.leftAccessoryView.$width + self.rightAccessoryView.$width + ACCESSORY_MARGIN*2;
        
        if (self.leftAccessoryView && self.rightAccessoryView)
            preferredWidth += BETWEEN_ACCESSORIES_MARGIN;
    }
    
    // ensure we're big enough to fit our graphics!
    preferredWidth = fmaxf(preferredWidth, CALLOUT_DEFAULT_MIN_WIDTH);
    
    // ask to be smaller if we have space, otherwise we'll fit into what we have by truncating the title/subtitle.
    return CGSizeMake(fminf(preferredWidth, size.width), self.calloutHeight);
}

- (CGSize)offsetToContainRect:(CGRect)innerRect inRect:(CGRect)outerRect {
    CGFloat nudgeRight = fmaxf(0, CGRectGetMinX(outerRect) - CGRectGetMinX(innerRect));
    CGFloat nudgeLeft = fminf(0, CGRectGetMaxX(outerRect) - CGRectGetMaxX(innerRect));
    CGFloat nudgeTop = fmaxf(0, CGRectGetMinY(outerRect) - CGRectGetMinY(innerRect));
    CGFloat nudgeBottom = fminf(0, CGRectGetMaxY(outerRect) - CGRectGetMaxY(innerRect));
    return CGSizeMake(nudgeLeft ?: nudgeRight, nudgeTop ?: nudgeBottom);
}

- (void)presentCalloutFromRect:(CGRect)rect inView:(UIView *)view constrainedToView:(UIView *)constrainedView permittedArrowDirections:(SMCalloutArrowDirection)arrowDirections animated:(BOOL)animated {
    [self presentCalloutFromRect:rect inLayer:view.layer ofView:view constrainedToLayer:constrainedView.layer permittedArrowDirections:arrowDirections animated:animated];
}

- (void)presentCalloutFromRect:(CGRect)rect inLayer:(CALayer *)layer constrainedToLayer:(CALayer *)constrainedLayer permittedArrowDirections:(SMCalloutArrowDirection)arrowDirections animated:(BOOL)animated {
    [self presentCalloutFromRect:rect inLayer:layer ofView:nil constrainedToLayer:constrainedLayer permittedArrowDirections:arrowDirections animated:animated];
}

// this private method handles both CALayer and UIView parents depending on what's passed.
- (void)presentCalloutFromRect:(CGRect)rect inLayer:(CALayer *)layer ofView:(UIView *)view constrainedToLayer:(CALayer *)constrainedLayer permittedArrowDirections:(SMCalloutArrowDirection)arrowDirections animated:(BOOL)animated {
    
    // Sanity check: dismiss this callout immediately if it's displayed somewhere
    if (self.layer.superlayer) [self dismissCalloutAnimated:NO];
    
    // figure out the constrained view's rect in our popup view's coordinate system
    CGRect constrainedRect = [constrainedLayer convertRect:constrainedLayer.bounds toLayer:layer];
    
    // form our subviews based on our content set so far
    [self rebuildSubviews];
    
    // apply title/subtitle (if present
    titleLabel.text = self.title;
    subtitleLabel.text = self.subtitle;
    
    // size the callout to fit the width constraint as best as possible
    self.$size = [self sizeThatFits:CGSizeMake(constrainedRect.size.width, self.calloutHeight)];
    
    // how much room do we have in the constraint box, both above and below our target rect?
    CGFloat topSpace = CGRectGetMinY(rect) - CGRectGetMinY(constrainedRect);
    CGFloat bottomSpace = CGRectGetMaxY(constrainedRect) - CGRectGetMaxY(rect);
    
    // we prefer to point our arrow down.
    SMCalloutArrowDirection bestDirection = SMCalloutArrowDirectionDown;
    
    // we'll point it up though if that's the only option you gave us.
    if (arrowDirections == SMCalloutArrowDirectionUp)
        bestDirection = SMCalloutArrowDirectionUp;
    
    // or, if we don't have enough space on the top and have more space on the bottom, and you
    // gave us a choice, then pointing up is the better option.
    if (arrowDirections == SMCalloutArrowDirectionAny && topSpace < self.calloutHeight && bottomSpace > topSpace)
        bestDirection = SMCalloutArrowDirectionUp;
    
    // show the correct anchor based on our decision
    topAnchor.hidden = (bestDirection == SMCalloutArrowDirectionDown);
    bottomAnchor.hidden = (bestDirection == SMCalloutArrowDirectionUp);
    arrowDirection = bestDirection;
    
    // we want to point directly at the horizontal center of the given rect. calculate our "anchor point" in terms of our
    // target view's coordinate system. make sure to offset the anchor point as requested if necessary.
    CGFloat anchorX = self.calloutOffset.x + CGRectGetMidX(rect);
    CGFloat anchorY = self.calloutOffset.y + (bestDirection == SMCalloutArrowDirectionDown ? CGRectGetMinY(rect) : CGRectGetMaxY(rect));
    
    // we prefer to sit in the exact center of our constrained view, so we have visually pleasing equal left/right margins.
    CGFloat calloutX = roundf(CGRectGetMidX(constrainedRect) - self.$width / 2);
    
    // what's the farthest to the left and right that we could point to, given our background image constraints?
    CGFloat minPointX = calloutX + ANCHOR_MARGIN;
    CGFloat maxPointX = calloutX + self.$width - ANCHOR_MARGIN;
    
    // we may need to scoot over to the left or right to point at the correct spot
    CGFloat adjustX = 0;
    if (anchorX < minPointX) adjustX = anchorX - minPointX;
    if (anchorX > maxPointX) adjustX = anchorX - maxPointX;
    
    // add the callout to the given layer (or view if possible, to receive touch events)
    if (view)
        [view addSubview:self];
    else
        [layer addSublayer:self.layer];
    
    CGPoint calloutOrigin = {
        .x = calloutX + adjustX,
        .y = bestDirection == SMCalloutArrowDirectionDown ? (anchorY - self.calloutHeight + BOTTOM_ANCHOR_MARGIN) : anchorY
    };
    
    _currentArrowDirection = bestDirection;
    
    self.$origin = calloutOrigin;
    
    // now set the *actual* anchor point for our layer so that our "popup" animation starts from this point.
    CGPoint anchorPoint = [layer convertPoint:CGPointMake(anchorX, anchorY) toLayer:self.layer];
    
    // pass on the anchor point to our background view so it knows where to draw the arrow
    self.backgroundView.arrowPoint = anchorPoint;

    // adjust it to unit coordinates for the actual layer.anchorPoint property
    anchorPoint.x /= self.$width;
    anchorPoint.y /= self.$height;
    self.layer.anchorPoint = anchorPoint;
    
    // setting the anchor point moves the view a bit, so we need to reset
    self.$origin = calloutOrigin;
    
    // make sure our frame is not on half-pixels or else we may be blurry!
    self.frame = CGRectIntegral(self.frame);

    // layout now so we can immediately start animating to the final position if needed
    [self setNeedsLayout];
    [self layoutIfNeeded];
    
    // if we're outside the bounds of our constraint rect, we'll give our delegate an opportunity to shift us into position.
    // consider both our size and the size of our target rect (which we'll assume to be the size of the content you want to scroll into view.
    CGRect contentRect = CGRectUnion(self.frame, CGRectInset(rect, -REPOSITION_MARGIN, -REPOSITION_MARGIN));
    CGSize offset = [self offsetToContainRect:contentRect inRect:constrainedRect];
    
    NSTimeInterval delay = 0;
    popupCancelled = NO; // reset this before calling our delegate below
    
    if ([self.delegate respondsToSelector:@selector(calloutView:delayForRepositionWithSize:)] && !CGSizeEqualToSize(offset, CGSizeZero))
        delay = [self.delegate calloutView:self delayForRepositionWithSize:offset];
    
    // there's a chance that user code in the delegate method may have called -dismissCalloutAnimated to cancel things; if that
    // happened then we need to bail!
    if (popupCancelled) return;
    
    // if we need to delay, we don't want to be visible while we're delaying, so hide us in preparation for our popup
    self.hidden = YES;
    
    // create the appropriate animation, even if we're not animated
    CAAnimation *animation = [self animationWithType:self.presentAnimation presenting:YES];
    
    // nuke the duration if no animation requested - we'll still need to "run" the animation to get delays and callbacks
    if (!animated)
        animation.duration = 0.0000001; // can't be zero or the animation won't "run"
    
    animation.beginTime = CACurrentMediaTime() + delay;
    animation.delegate = self;
    
    [self.layer addAnimation:animation forKey:@"present"];
}

- (void)animationDidStart:(CAAnimation *)anim {
    BOOL presenting = [[anim valueForKey:@"presenting"] boolValue];

    if (presenting) {
        if ([_delegate respondsToSelector:@selector(calloutViewWillAppear:)])
            [_delegate calloutViewWillAppear:self];
        
        // ok, animation is on, let's make ourselves visible!
        self.hidden = NO;
    }
    else if (!presenting) {
        if ([_delegate respondsToSelector:@selector(calloutViewWillDisappear:)])
            [_delegate calloutViewWillDisappear:self];
    }
}

- (void)animationDidStop:(CAAnimation *)anim finished:(BOOL)finished {
    BOOL presenting = [[anim valueForKey:@"presenting"] boolValue];
    
    if (presenting) {
        if ([_delegate respondsToSelector:@selector(calloutViewDidAppear:)])
            [_delegate calloutViewDidAppear:self];
    }
    else if (!presenting) {
        
        [self removeFromParent];
        [self.layer removeAnimationForKey:@"dismiss"];

        if ([_delegate respondsToSelector:@selector(calloutViewDidDisappear:)])
            [_delegate calloutViewDidDisappear:self];
    }
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    // we want to match the system callout view, which doesn't "capture" touches outside the accessory areas. This way you can click on other pins and things *behind* a translucent callout.
    return
        [self.leftAccessoryView pointInside:[self.leftAccessoryView convertPoint:point fromView:self] withEvent:nil] ||
        [self.rightAccessoryView pointInside:[self.rightAccessoryView convertPoint:point fromView:self] withEvent:nil] ||
        [self.contentView pointInside:[self.contentView convertPoint:point fromView:self] withEvent:nil] ||
        (!self.contentView && [self.titleView pointInside:[self.titleView convertPoint:point fromView:self] withEvent:nil]) ||
        (!self.contentView && [self.subtitleView pointInside:[self.subtitleView convertPoint:point fromView:self] withEvent:nil]);
}

- (void)dismissCalloutAnimated:(BOOL)animated {
    [self.layer removeAnimationForKey:@"present"];
    
    popupCancelled = YES;
    
    if (animated) {
        CAAnimation *animation = [self animationWithType:self.dismissAnimation presenting:NO];
        animation.delegate = self;
        [self.layer addAnimation:animation forKey:@"dismiss"];
    }
    else [self removeFromParent];
}

- (void)removeFromParent {
    if (self.superview)
        [self removeFromSuperview];
    else {
        // removing a layer from a superlayer causes an implicit fade-out animation that we wish to disable.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [self.layer removeFromSuperlayer];
        [CATransaction commit];
    }
}

- (CAAnimation *)animationWithType:(SMCalloutAnimation)type presenting:(BOOL)presenting {
    CAAnimation *animation = nil;
    
    if (type == SMCalloutAnimationBounce) {
        CAKeyframeAnimation *bounceAnimation = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        CAMediaTimingFunction *easeInOut = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        
        bounceAnimation.values = @[@0.05, @1.11245, @0.951807, @1.0];
        bounceAnimation.keyTimes = @[@0, @(4.0/9.0), @(4.0/9.0+5.0/18.0), @1.0];
        bounceAnimation.duration = 1.0/3.0; // the official bounce animation duration adds up to 0.3 seconds; but there is a bit of delay introduced by Apple using a sequence of callback-based CABasicAnimations rather than a single CAKeyframeAnimation. So we bump it up to 0.33333 to make it feel identical on the device
        bounceAnimation.timingFunctions = @[easeInOut, easeInOut, easeInOut, easeInOut];
        
        if (!presenting)
            bounceAnimation.values = [[bounceAnimation.values reverseObjectEnumerator] allObjects]; // reverse values
        
        animation = bounceAnimation;
    }
    else if (type == SMCalloutAnimationFade) {
        CABasicAnimation *fadeAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fadeAnimation.duration = 1.0/3.0;
        fadeAnimation.fromValue = presenting ? @0.0 : @1.0;
        fadeAnimation.toValue = presenting ? @1.0 : @0.0;
        animation = fadeAnimation;
    }
    else if (type == SMCalloutAnimationStretch) {
        CABasicAnimation *stretchAnimation = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        stretchAnimation.duration = 0.1;
        stretchAnimation.fromValue = presenting ? @0.0 : @1.0;
        stretchAnimation.toValue = presenting ? @1.0 : @0.0;
        animation = stretchAnimation;
    }
    
    // CAAnimation is KVC compliant, so we can store whether we're presenting for lookup in our delegate methods
    [animation setValue:@(presenting) forKey:@"presenting"];
    
    animation.fillMode = kCAFillModeForwards;
    animation.removedOnCompletion = NO;
    return animation;
}

- (CGFloat)centeredPositionOfView:(UIView *)view ifSmallerThan:(CGFloat)height {
    return view.$height < height ? floorf(height/2 - view.$height/2) : 0;
}

- (CGFloat)centeredPositionOfView:(UIView *)view relativeToView:(UIView *)parentView {
    return roundf((parentView.$height - view.$height) / 2);
}

- (void)layoutSubviews {
    
    self.backgroundView.frame = self.bounds;
    
    // if we're pointing up, we'll need to push almost everything down a bit
    CGFloat dy = arrowDirection == SMCalloutArrowDirectionUp ? TOP_ANCHOR_MARGIN : 0;
    
    self.titleViewOrDefault.$x = self.innerContentMarginLeft;
    self.titleViewOrDefault.$y = (self.subtitleView || self.subtitle.length ? TITLE_SUB_TOP : TITLE_TOP) + dy;
    self.titleViewOrDefault.$width = self.$width - self.innerContentMarginLeft - self.innerContentMarginRight;
    
    self.subtitleViewOrDefault.$x = self.titleViewOrDefault.$x;
    self.subtitleViewOrDefault.$y = SUBTITLE_TOP + dy;
    self.subtitleViewOrDefault.$width = self.titleViewOrDefault.$width;
    
    self.leftAccessoryView.$x = ACCESSORY_MARGIN;
    if (self.contentView)
        self.leftAccessoryView.$y = TITLE_TOP + [self centeredPositionOfView:self.leftAccessoryView relativeToView:self.contentView] + dy;
    else
        self.leftAccessoryView.$y = ACCESSORY_TOP + [self centeredPositionOfView:self.leftAccessoryView ifSmallerThan:ACCESSORY_HEIGHT] + dy;
    
    self.rightAccessoryView.$x = self.$width-ACCESSORY_MARGIN-self.rightAccessoryView.$width;
    if (self.contentView)
        self.rightAccessoryView.$y = TITLE_TOP + [self centeredPositionOfView:self.rightAccessoryView relativeToView:self.contentView] + dy;
    else
        self.rightAccessoryView.$y = ACCESSORY_TOP + [self centeredPositionOfView:self.rightAccessoryView ifSmallerThan:ACCESSORY_HEIGHT] + dy;
    
    
    if (self.contentView) {
        self.contentView.$x = self.innerContentMarginLeft;
        self.contentView.$y = TITLE_TOP + dy;
    }
}

@end

//
// Callout background base class, includes graphics for +systemBackgroundView
//
@implementation SMCalloutBackgroundView

+ (SMCalloutBackgroundView *)systemBackgroundView {
    SMCalloutImageBackgroundView *background = [SMCalloutImageBackgroundView new];
    background.leftCapImage = [[self embeddedImageNamed:@"SMCalloutViewLeftCap"] stretchableImageWithLeftCapWidth:16 topCapHeight:20];
    background.rightCapImage = [[self embeddedImageNamed:@"SMCalloutViewRightCap"] stretchableImageWithLeftCapWidth:0 topCapHeight:20];
    background.topAnchorImage = [[self embeddedImageNamed:@"SMCalloutViewTopAnchor"] stretchableImageWithLeftCapWidth:0 topCapHeight:33];
    background.bottomAnchorImage = [[self embeddedImageNamed:@"SMCalloutViewBottomAnchor"] stretchableImageWithLeftCapWidth:0 topCapHeight:20];
    background.backgroundImage = [[self embeddedImageNamed:@"SMCalloutViewBackground"] stretchableImageWithLeftCapWidth:0 topCapHeight:20];
    return background;
}

+ (NSData *)dataWithBase64EncodedString:(NSString *)string {
    //
    //  NSData+Base64.m
    //
    //  Version 1.0.2
    //
    //  Created by Nick Lockwood on 12/01/2012.
    //  Copyright (C) 2012 Charcoal Design
    //
    //  Distributed under the permissive zlib License
    //  Get the latest version from here:
    //
    //  https://github.com/nicklockwood/Base64
    //
    //  This software is provided 'as-is', without any express or implied
    //  warranty.  In no event will the authors be held liable for any damages
    //  arising from the use of this software.
    //
    //  Permission is granted to anyone to use this software for any purpose,
    //  including commercial applications, and to alter it and redistribute it
    //  freely, subject to the following restrictions:
    //
    //  1. The origin of this software must not be misrepresented; you must not
    //  claim that you wrote the original software. If you use this software
    //  in a product, an acknowledgment in the product documentation would be
    //  appreciated but is not required.
    //
    //  2. Altered source versions must be plainly marked as such, and must not be
    //  misrepresented as being the original software.
    //
    //  3. This notice may not be removed or altered from any source distribution.
    //
    const char lookup[] = {
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 62, 99, 99, 99, 63,
        52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 99, 99, 99, 99, 99, 99,
        99,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14,
        15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 99, 99, 99, 99, 99,
        99, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
        41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 99, 99, 99, 99, 99
    };
    
    NSData *inputData = [string dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES];
    long long inputLength = [inputData length];
    const unsigned char *inputBytes = [inputData bytes];
    
    long long maxOutputLength = (inputLength / 4 + 1) * 3;
    NSMutableData *outputData = [NSMutableData dataWithLength:maxOutputLength];
    unsigned char *outputBytes = (unsigned char *)[outputData mutableBytes];
    
    int accumulator = 0;
    long long outputLength = 0;
    unsigned char accumulated[] = {0, 0, 0, 0};
    for (long long i = 0; i < inputLength; i++) {
        unsigned char decoded = lookup[inputBytes[i] & 0x7F];
        if (decoded != 99) {
            accumulated[accumulator] = decoded;
            if (accumulator == 3) {
                outputBytes[outputLength++] = (accumulated[0] << 2) | (accumulated[1] >> 4);
                outputBytes[outputLength++] = (accumulated[1] << 4) | (accumulated[2] >> 2);
                outputBytes[outputLength++] = (accumulated[2] << 6) | accumulated[3];
            }
            accumulator = (accumulator + 1) % 4;
        }
    }
    
    //handle left-over data
    if (accumulator > 0) outputBytes[outputLength] = (accumulated[0] << 2) | (accumulated[1] >> 4);
    if (accumulator > 1) outputBytes[++outputLength] = (accumulated[1] << 4) | (accumulated[2] >> 2);
    if (accumulator > 2) outputLength++;
    
    //truncate data to match actual output length
    outputData.length = outputLength;
    return outputLength? outputData: nil;
}

+ (UIImage *)embeddedImageNamed:(NSString *)name {
    if ([UIScreen mainScreen].scale == 2)
        name = [name stringByAppendingString:@"$2x"];
    
    SEL selector = NSSelectorFromString(name);
    
    if (![(id)self respondsToSelector:selector]) {
        NSLog(@"Could not find an embedded image. Ensure that you've added a category method to UIImage named +%@", name);
        return nil;
    }
    
    // We need to hush the compiler here - but we know what we're doing!
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSString *base64String = [(id)self performSelector:selector];
    #pragma clang diagnostic pop
    
    UIImage *rawImage = [UIImage imageWithData:[self dataWithBase64EncodedString:base64String]];
    return [UIImage imageWithCGImage:rawImage.CGImage scale:[UIScreen mainScreen].scale orientation:UIImageOrientationUp];
}

//
// I didn't want this class to require adding any images to your Xcode project. So instead the images needed are embedded below.
//

+ (NSString *)SMCalloutViewBackground { return @"iVBORw0KGgoAAAANSUhEUgAAAAEAAAA5CAYAAAD3PEFJAAAAXUlEQVQYGX1PSQrAMAiU5Jw/9f8vKb141B6qVRMQJG0gwyyMKKgqNLDXEPECItIpM9ixaASIyBqQXjQ+ayVIGQNK99/LtLCQzHw6Ofyix+HuBsOhO4h9W75sME3DF8fUR+HpNDTFAAAAAElFTkSuQmCC"; }
+ (NSString *)SMCalloutViewBackground$2x { return @"iVBORw0KGgoAAAANSUhEUgAAAAIAAAByCAYAAAB5lADlAAAAzElEQVQ4EZ2RAQ7CMAwDKfRh/P8d+wOg0o6dpXiKmKpBpFZO4sRJW9Z1vWBX3YegLssiUmmtCdTeu/j1RLk6w7uabJBExSmlKHiKDJMCS/w2j9WP5yHtZ5l0zqk0z76FtQDaFGDyGGPXUpVTJlPgebzyTILS3MebElZDR+SGRBY9w6FcVVxZ9DsV6vnp4M3WIY/NONF555wdns6ep0afys9gPNcd4C+om6NcAm84RFqAV4BngEcARW6bx+lcyAwANvD0T+V4C0ie5z/wAdmBoztY1KTNAAAAAElFTkSuQmCC"; }
+ (NSString *)SMCalloutViewBottomAnchor { return @"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"; }
+ (NSString *)SMCalloutViewBottomAnchor$2x { return @"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"; }
+ (NSString *)SMCalloutViewLeftCap { return @"iVBORw0KGgoAAAANSUhEUgAAABEAAAA5CAYAAADQksChAAACq0lEQVRIDd2XTW4TQRCFMzOZ4IQf2xuEkLKINyyR2HAExA04iReB87BDPgBbruAlW1v23hEO2KY+a96opt3tGewdLXWqprveV697gphku93u4tyRnwtAf9kGWSwWX7Is+1iW5WurfRqrT0Jms9ltnuffhsPhWxNeSczxDXrhryEJMdH3wWDwhmIJPcjn0TuZz+efDXBHoQCCaU0QXB1AbDG3+cHmFcJQ5NcEbkBMmJnIriJ/pYI2CPsNSPVcGuuGzS6DZvXFyoUJL7fbba0nx6Bf05EoYi90wnFKKyJ2GgA9ZH8fpiyA0FndFaHKBVF5fZyqLaCGCxUqelClaTjR2t6FHtoiLkMntcZ3rhcTib+TRgkQgRQpUO73k05E9KJwTdB/diKQj1EndOeXSJ3I5ciLlUchEqvoGICaThDBiHLlnSYhXuhzuVJk7ySI3AiehPhOKlYM95KvWIIu8SQnHszRohBvlzy8Aw9hP3kcNgVTRKzc70ed+GLfVblAek46UUFbBJh0IjFFx+4kebEAvGWfC+5j63EEIPpcENaSx5GAYp9L7GMUckykPR9bj+M7knsxeeeLTYEEbXUSdpbQg6N3EhYK5Nf9WhRi/6s9+CLfNZZHj7Nerxex4tRaFLJcLn9sNptH3LRNwJls26sC+MTmc5vD6XT6td/vv+MVto3QCV96zO14PL5frVY/7X72jgRSUzlk3TuhZWnzmc1+NW8mk8mn0Wj0vtfrvSyK4tqcHfwxEEJ4Wz2bLyoIn+F8TRc2aRI9W/2Kzd7OuvDF98fmL5u40nGVH4eYgAHkt00gArCGGxpG3dROrIDXKTePPNsQVBDAB27qO9lLqh/V60bAMWhETN5LFGIC/onTEZC6K7LdGEmIqioYjwfHqGvsGpSfHLF49vjPIH8BR5jVbMlfl2gAAAAASUVORK5CYII="; }
+ (NSString *)SMCalloutViewLeftCap$2x { return @"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"; }
+ (NSString *)SMCalloutViewRightCap { return @"iVBORw0KGgoAAAANSUhEUgAAABEAAAA5CAYAAADQksChAAAC80lEQVRIDd1XTa4SQRBmBgy4MXEBgSt4ApfvDC5lzQk8golcwLjxCias3LlxTXhLNiYu0ISXlxgyLyIIA1hfMd/YU3QPQ3BlJT1VXT9f/UyTaaLD4VC7luJrARDfWCwW9z4gqXAn60eapl/jOH7Vbre/+Pygi1arVd5PFEU1tAcOgiwAtSRJ7kV+2+l0XqvBPBQEziALQl/o1+v1gyR82e12P1JPHjOzCwAdgSk3m80n9Xr9zWQyecRgch0sHaFksCvT3mq1nvV6vReS8NhvhqKV0MkNdGXapZKGyM/FVgTJwCqz7Xb7VJzrbjVAzt/Gfr9XGZwEOwldyCtvyL4uaydLjRcdtqwttAKgvCUFQWZmJxenfMhZMFS13W6HGF1sCYg5sXRyGFw526OCvAroYjczFGXk+BaAtBKbrQzIZ9OZAIRA5HCm7Np9IBfNhKAWqPTEWufQvnDYkAkHKpQxCAKDG+TKoSCr10qskntWBQ4KJSgMlsHkDCKn3vKzIKzGBrr70nbgeK4K+Ohhg3ANna3EBeeAXR3ki85JqLV/99sJZUCpZTbYQfrbOYrnnyHAi2YSHCzyuxlc+XxtR4/COSEAuCsTjDruyU/OSciRAT5emIl1IKDl1q/QjjW6wZArDzYEBD1BrU/hnNAJ3JVtkN2ffHcYDEfK5NDJB+zvFx4KoZO3c1T7nwATkMRaSwdrnWWw6Xw+v7X6iypZLpfTwWDwyYJUrkSuFMl4PH4/m814uclnUxgszgH65nmgLFfP79Pp9EO/3/8sVeAalQOgqobcT+8gWJIBppvNJpEW7obD4bvRaPRNfNJsAWgvSRQMX6UbWT5iNgQgeCXrIVs/hW8EQy93aAc9+gggWLD/lgWQdSZzLrI9XuDg4CMCbMWI4F/Z2gjHnwdWqrdAlOgj7VsMCEIiVoHWcgCRFWQBwUOsBKWjGizI+UBFVsJgH2eyZQDh0hlwkNYRIGUHTst2+7cA2EfOfHz2SrqyKioBwOk/A/kDNLw5zf2DJzkAAAAASUVORK5CYII="; }
+ (NSString *)SMCalloutViewRightCap$2x { return @"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"; }
+ (NSString *)SMCalloutViewTopAnchor { return @"iVBORw0KGgoAAAANSUhEUgAAACkAAABGCAYAAABRwr15AAAFpklEQVRoBe2ay2skVRTGU51KjxE75CEkQXDnaha6EQRdRNCF/4ALwZV/lyvBxbhyIY6PYfbuhNm5M4u8IOYhknd7voo/OXX63qrqSosteKHnO/c8vvPde+tWd2CK8Xi8MMtxdnb2hvhWVlZ+mRVvMUuRe3t7ry8tLX1v4orr6+sPt7e3f52JUImcxWd3d/e1g4ODF7e3t2N9jo6OXsg3C+7BLFZ6fn7+6nA4/HZ9ff0xfGtra49tV58qhq8vPvi4T05OVq+urp6bwLcWFxerUymKotJjO7pwfHz8sy1gZ3V19aSvyIfu5Oji4uKZBEpYPFr5LPamLeKZCRz1FTlBHBs1zB/ZRfnJLsj45uam8aMc5RrXowa+rJa+Ozm0S/J8Y2PjbY5WuyQBoLeVo1zVWHxYJU3xTx+R5eHh4Y92Md6JR4zAVP/BYLCgGqv9weJlKifnm1bkYH9//6ldgnet6f3tyDGb3++mbFtUYbXvGcd3Fu7cu3OitBj5N7Yb71uvgZrGj3IQ5m3yrE5CB8axIy7ldBmdRdrz9LXtwgdqkiNGIKKUh8/bdgoDcYkzx+X92YY+yZ6jJ/Zd/JG9B6d6ljyHbAQLTWcpTuP+KubFeevL3Fb7xWg0+rgsy6HIdWQ0myD7K6YcjZhPLXHl2Ovryr6Vnmxubn6qeWo0irTn5nNb7Se2gy+litt8UVQUTf3d3d3F6enpl1tbW5/h81jY19ahd2Bbg/Hy8vIrNn+ZnWtrOm2cXkKr/cPG79Zr4q1R2Nfa3z8ocyv1ZN6eVlTkb6unV8ku4Yhz/CkkN4eqIebtlA9+H8NXidSKIGF1JDQhudQ35SpGHihBcBDH57mqV4pX722fmLLJBZWTsr0v8vgYNkhu9Z6UM/VpagoRCGETkkuvyJ+rbTxuTyoCjiZ3XLkm+PvWNx63REJMI4Tn5vhTaO/Dik+oIW58qXx8E7ebAOhFYYMsQKghPz7qI1Ib/Zrn6h/0XcwudN2ZlIgoOs4lvnUnlcRgl9i5iCkR1IIpET5GD3zCxotDAWLiznki2cojR/MoOvIhOIfkt14cmgk1ILyf1f8lBsZ8/GC9+n7mY9i135M4hd5OkfXxeU56eBQnOZ5/4pn0SdigL+xrey6OU6ihGD7PX/2tggMCobeJzxp9D2/HPlM9k6yybeWxSW7elW+qZ9Kv1ts5EW1+z+HtWNe4kzE5zkXMbsRYnzlc8aQmLo4nj6uLokTm34u+to8d+4lDvtrLvI2YFYJRdKxXHjk0xKc5dhvfxHHHRm1zVt+1qc/HBnOiazupZBJTTaPgmK84Db2ND252LvLx6AgZqi0plBMbkpQIikEEaI4Nep+3fVx+P1KxMqpWgU/0tieT3WdRnqNrffVM+sJpbBYAqtbbkUsxhBGL+XGuvMZnEiKQBsLUiCLa8iNHrCc+cbtTKyGZGIjfo49hg8pL2Smf56z9SdtEAhHoc+VLfXyOb4oNF7Uxn3jtGwcnGIsgz2E8XvHgy9WkeuGjtvZM5ojw595jxIU08DY+mgq7DPrVbrfIIMqR0DAX937EgF34fb1s1TRenEjKAmiaIoQYpEZz2eyO5nHk+v2jvydZjBCxoARpgFGwj9Uujg+kiqKPBmCMxzl5oOLeTs3lq10cFbBSBdsGuUKNWB/j5IFt+fRvfCZJyiG7ACovZXtf5PIxbJDcieMm0AfjzqkZvi585MadbnwFxaLYKCXC7wI22MbHzRdqKF927bgjSUqEF9qW3xb3XIiip+bY1e9JkeFswlRTn5+z2ckY19wP8kDFZNeO2xfIRjyoAoTGXPLJScWJCVMD7tivvLy83E8VzJNP57wzT4JSWnTct6nAPPkk8nKeBKW0SORZKjBPPon8bZ4EpbTo4iynAvPkk8jab8p5EoeWxv/eQNK/jXO/i9qg/0XO6jH5T+zkny+SJQg+lJzfAAAAAElFTkSuQmCC"; }
+ (NSString *)SMCalloutViewTopAnchor$2x { return @"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"; }

@end

//
// Callout background assembled from predrawn stretched images.
//
@implementation SMCalloutImageBackgroundView {
    UIImageView *leftCap, *rightCap, *topAnchor, *bottomAnchor, *leftBackground, *rightBackground;
}

- (id)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        leftCap = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 17, 57)];
        rightCap = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 17, 57)];
        topAnchor = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 41, 70)];
        bottomAnchor = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 41, 70)];
        leftBackground = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 1, 57)];
        rightBackground = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 1, 57)];
        [self addSubview:leftCap];
        [self addSubview:rightCap];
        [self addSubview:topAnchor];
        [self addSubview:bottomAnchor];
        [self addSubview:leftBackground];
        [self addSubview:rightBackground];
    }
    return self;
}

// Make sure we relayout our images when our arrow point changes!
- (void)setArrowPoint:(CGPoint)arrowPoint {
    [super setArrowPoint:arrowPoint];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    
    // apply our background graphics
    leftCap.image = self.leftCapImage;
    rightCap.image = self.rightCapImage;
    topAnchor.image = self.topAnchorImage;
    bottomAnchor.image = self.bottomAnchorImage;
    leftBackground.image = self.backgroundImage;
    rightBackground.image = self.backgroundImage;
    
    // stretch the images to fill our vertical space. The system background images aren't really stretchable,
    // but that's OK because you'll probably be using title/subtitle rather than contentView if you're using the
    // system images, and in that case the height will match the system background heights exactly and no stretching
    // will occur. However, if you wish to define your own custom background using prerendered images, you could
    // define stretchable images using -stretchableImageWithLeftCapWidth:TopCapHeight and they'd get stretched
    // properly here if necessary.
    leftCap.$height = rightCap.$height = leftBackground.$height = rightBackground.$height = self.$height - 13;
    topAnchor.$height = bottomAnchor.$height = self.$height;

    BOOL pointingUp = self.arrowPoint.y < self.$height/2;

    // show the correct anchor based on our direction
    topAnchor.hidden = !pointingUp;
    bottomAnchor.hidden = pointingUp;

    // if we're pointing up, we'll need to push almost everything down a bit
    CGFloat dy = pointingUp ? TOP_ANCHOR_MARGIN : 0;
    leftCap.$y = rightCap.$y = leftBackground.$y = rightBackground.$y = dy;
    
    leftCap.$x = 0;
    rightCap.$x = self.$width - rightCap.$width;
    
    // move both anchors, only one will have been made visible in our -popup method
    CGFloat anchorX = roundf(self.arrowPoint.x - bottomAnchor.$width / 2);
    topAnchor.$origin = CGPointMake(anchorX, 0);
    
    // make sure the anchor graphic isn't overlapping with an endcap
    if (topAnchor.$left < leftCap.$right) topAnchor.$x = leftCap.$right;
    if (topAnchor.$right > rightCap.$left) topAnchor.$x = rightCap.$left - topAnchor.$width; // don't stretch it
    
    bottomAnchor.$origin = topAnchor.$origin; // match
    
    leftBackground.$left = leftCap.$right;
    leftBackground.$right = topAnchor.$left;
    rightBackground.$left = topAnchor.$right;
    rightBackground.$right = rightCap.$left;
}

@end

//
// Custom-drawn flexible-height background implementation.
// Contributed by Nicholas Shipes: https://github.com/u10int
//
@implementation SMCalloutDrawnBackgroundView

- (id)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
    }
    return self;
}

// Make sure we redraw our graphics when the arrow point changes!
- (void)setArrowPoint:(CGPoint)arrowPoint {
    [super setArrowPoint:arrowPoint];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {

    BOOL pointingUp = self.arrowPoint.y < self.$height/2;
    CGSize anchorSize = CGSizeMake(27, ANCHOR_HEIGHT);
    CGFloat anchorX = roundf(self.arrowPoint.x - anchorSize.width / 2);
    CGRect anchorRect = CGRectMake(anchorX, 0, anchorSize.width, anchorSize.height);
    
    // make sure the anchor is not too close to the end caps
    if (anchorRect.origin.x < ANCHOR_MARGIN_MIN)
        anchorRect.origin.x = ANCHOR_MARGIN_MIN;
    
    else if (anchorRect.origin.x + anchorRect.size.width > self.$width - ANCHOR_MARGIN_MIN)
        anchorRect.origin.x = self.$width - anchorRect.size.width - ANCHOR_MARGIN_MIN;
    
    // determine size
    CGFloat stroke = 1.0;
    CGFloat radius = [UIScreen mainScreen].scale == 1 ? 4.5 : 6.0;
    
    rect = CGRectMake(self.bounds.origin.x, self.bounds.origin.y + TOP_SHADOW_BUFFER, self.bounds.size.width, self.bounds.size.height - ANCHOR_HEIGHT);
    rect.size.width -= stroke + 14;
    rect.size.height -= stroke * 2 + TOP_SHADOW_BUFFER + BOTTOM_SHADOW_BUFFER + OFFSET_FROM_ORIGIN;
    rect.origin.x += stroke / 2.0 + 7;
    rect.origin.y += pointingUp ? ANCHOR_HEIGHT - stroke / 2.0 : stroke / 2.0;
    
    
    // General Declarations
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    // Color Declarations
    UIColor* fillBlack = [UIColor colorWithRed: 0.11 green: 0.11 blue: 0.11 alpha: 1];
    UIColor* shadowBlack = [UIColor colorWithRed: 0 green: 0 blue: 0 alpha: 0.47];
    UIColor* glossBottom = [UIColor colorWithRed: 1 green: 1 blue: 1 alpha: 0.2];
    UIColor* glossTop = [UIColor colorWithRed: 1 green: 1 blue: 1 alpha: 0.85];
    UIColor* strokeColor = [UIColor colorWithRed: 0.199 green: 0.199 blue: 0.199 alpha: 1];
    UIColor* innerShadowColor = [UIColor colorWithRed: 1 green: 1 blue: 1 alpha: 0.4];
    UIColor* innerStrokeColor = [UIColor colorWithRed: 0.821 green: 0.821 blue: 0.821 alpha: 0.04];
    UIColor* outerStrokeColor = [UIColor colorWithRed: 0 green: 0 blue: 0 alpha: 0.35];
    
    // Gradient Declarations
    NSArray* glossFillColors = [NSArray arrayWithObjects:
                                (id)glossBottom.CGColor,
                                (id)glossTop.CGColor, nil];
    CGFloat glossFillLocations[] = {0, 1};
    CGGradientRef glossFill = CGGradientCreateWithColors(colorSpace, (__bridge CFArrayRef)glossFillColors, glossFillLocations);
    
    // Shadow Declarations
    UIColor* baseShadow = shadowBlack;
    CGSize baseShadowOffset = CGSizeMake(0.1, 6.1);
    CGFloat baseShadowBlurRadius = 6;
    UIColor* innerShadow = innerShadowColor;
    CGSize innerShadowOffset = CGSizeMake(0.1, 1.1);
    CGFloat innerShadowBlurRadius = 1;
    
    CGFloat backgroundStrokeWidth = 1;
    CGFloat outerStrokeStrokeWidth = 1;
    
    // Frames
    CGRect frame = rect;
    CGRect innerFrame = CGRectMake(frame.origin.x + backgroundStrokeWidth, frame.origin.y + backgroundStrokeWidth, frame.size.width - backgroundStrokeWidth * 2, frame.size.height - backgroundStrokeWidth * 2);
    CGRect glossFrame = CGRectMake(frame.origin.x - backgroundStrokeWidth / 2, frame.origin.y - backgroundStrokeWidth / 2, frame.size.width + backgroundStrokeWidth, frame.size.height / 2 + backgroundStrokeWidth + 0.5);
    
    //// CoreGroup ////
    {
        CGContextSaveGState(context);
        CGContextSetAlpha(context, 0.83);
        CGContextBeginTransparencyLayer(context, NULL);
        
        // Background Drawing
        UIBezierPath* backgroundPath = [UIBezierPath bezierPath];
        [backgroundPath moveToPoint:CGPointMake(CGRectGetMinX(frame), CGRectGetMinY(frame) + radius)];
        [backgroundPath addLineToPoint:CGPointMake(CGRectGetMinX(frame), CGRectGetMaxY(frame) - radius)]; // left
        [backgroundPath addArcWithCenter:CGPointMake(CGRectGetMinX(frame) + radius, CGRectGetMaxY(frame) - radius) radius:radius startAngle:M_PI endAngle:M_PI / 2 clockwise:NO]; // bottom-left corner
        
        // pointer down
        if (!pointingUp) {
            [backgroundPath addLineToPoint:CGPointMake(CGRectGetMinX(anchorRect), CGRectGetMaxY(frame))];
            [backgroundPath addLineToPoint:CGPointMake(CGRectGetMinX(anchorRect) + anchorRect.size.width / 2, CGRectGetMaxY(frame) + anchorRect.size.height)];
            [backgroundPath addLineToPoint:CGPointMake(CGRectGetMaxX(anchorRect), CGRectGetMaxY(frame))];
        }
        
        [backgroundPath addLineToPoint:CGPointMake(CGRectGetMaxX(frame) - radius, CGRectGetMaxY(frame))]; // bottom
        [backgroundPath addArcWithCenter:CGPointMake(CGRectGetMaxX(frame) - radius, CGRectGetMaxY(frame) - radius) radius:radius startAngle:M_PI / 2 endAngle:0.0f clockwise:NO]; // bottom-right corner
        [backgroundPath addLineToPoint: CGPointMake(CGRectGetMaxX(frame), CGRectGetMinY(frame) + radius)]; // right
        [backgroundPath addArcWithCenter:CGPointMake(CGRectGetMaxX(frame) - radius, CGRectGetMinY(frame) + radius) radius:radius startAngle:0.0f endAngle:-M_PI / 2 clockwise:NO]; // top-right corner
        
        // pointer up
        if (pointingUp) {
            [backgroundPath addLineToPoint:CGPointMake(CGRectGetMaxX(anchorRect), CGRectGetMinY(frame))];
            [backgroundPath addLineToPoint:CGPointMake(CGRectGetMinX(anchorRect) + anchorRect.size.width / 2, CGRectGetMinY(frame) - anchorRect.size.height)];
            [backgroundPath addLineToPoint:CGPointMake(CGRectGetMinX(anchorRect), CGRectGetMinY(frame))];
        }
        
        [backgroundPath addLineToPoint:CGPointMake(CGRectGetMinX(frame) + radius, CGRectGetMinY(frame))]; // top
        [backgroundPath addArcWithCenter:CGPointMake(CGRectGetMinX(frame) + radius, CGRectGetMinY(frame) + radius) radius:radius startAngle:-M_PI / 2 endAngle:M_PI clockwise:NO]; // top-left corner
        [backgroundPath closePath];
        CGContextSaveGState(context);
        CGContextSetShadowWithColor(context, baseShadowOffset, baseShadowBlurRadius, baseShadow.CGColor);
        [fillBlack setFill];
        [backgroundPath fill];
        
        // Background Inner Shadow
        CGRect backgroundBorderRect = CGRectInset([backgroundPath bounds], -innerShadowBlurRadius, -innerShadowBlurRadius);
        backgroundBorderRect = CGRectOffset(backgroundBorderRect, -innerShadowOffset.width, -innerShadowOffset.height);
        backgroundBorderRect = CGRectInset(CGRectUnion(backgroundBorderRect, [backgroundPath bounds]), -1, -1);
        
        UIBezierPath* backgroundNegativePath = [UIBezierPath bezierPathWithRect: backgroundBorderRect];
        [backgroundNegativePath appendPath: backgroundPath];
        backgroundNegativePath.usesEvenOddFillRule = YES;
        
        CGContextSaveGState(context);
        {
            CGFloat xOffset = innerShadowOffset.width + round(backgroundBorderRect.size.width);
            CGFloat yOffset = innerShadowOffset.height;
            CGContextSetShadowWithColor(context,
                                        CGSizeMake(xOffset + copysign(0.1, xOffset), yOffset + copysign(0.1, yOffset)),
                                        innerShadowBlurRadius,
                                        innerShadow.CGColor);
            
            [backgroundPath addClip];
            CGAffineTransform transform = CGAffineTransformMakeTranslation(-round(backgroundBorderRect.size.width), 0);
            [backgroundNegativePath applyTransform: transform];
            [[UIColor grayColor] setFill];
            [backgroundNegativePath fill];
        }
        CGContextRestoreGState(context);
        
        CGContextRestoreGState(context);
        
        [strokeColor setStroke];
        backgroundPath.lineWidth = backgroundStrokeWidth;
        [backgroundPath stroke];
        
        
        // Inner Stroke Drawing
        CGFloat innerRadius = radius - 1.0;
        CGRect anchorInnerRect = anchorRect;
        anchorInnerRect.origin.x += backgroundStrokeWidth / 2;
        anchorInnerRect.origin.y -= backgroundStrokeWidth / 2;
        anchorInnerRect.size.width -= backgroundStrokeWidth;
        anchorInnerRect.size.height -= backgroundStrokeWidth / 2;
        
        UIBezierPath* innerStrokePath = [UIBezierPath bezierPath];
        [innerStrokePath moveToPoint:CGPointMake(CGRectGetMinX(innerFrame), CGRectGetMinY(innerFrame) + innerRadius)];
        [innerStrokePath addLineToPoint:CGPointMake(CGRectGetMinX(innerFrame), CGRectGetMaxY(innerFrame) - innerRadius)]; // left
        [innerStrokePath addArcWithCenter:CGPointMake(CGRectGetMinX(innerFrame) + innerRadius, CGRectGetMaxY(innerFrame) - innerRadius) radius:innerRadius startAngle:M_PI endAngle:M_PI / 2 clockwise:NO]; // bottom-left corner
        
        // pointer down
        if (!pointingUp) {
            [innerStrokePath addLineToPoint:CGPointMake(CGRectGetMinX(anchorInnerRect), CGRectGetMaxY(innerFrame))];
            [innerStrokePath addLineToPoint:CGPointMake(CGRectGetMinX(anchorInnerRect) + anchorInnerRect.size.width / 2, CGRectGetMaxY(innerFrame) + anchorInnerRect.size.height)];
            [innerStrokePath addLineToPoint:CGPointMake(CGRectGetMaxX(anchorInnerRect), CGRectGetMaxY(innerFrame))];
        }
        
        [innerStrokePath addLineToPoint:CGPointMake(CGRectGetMaxX(innerFrame) - innerRadius, CGRectGetMaxY(innerFrame))]; // bottom
        [innerStrokePath addArcWithCenter:CGPointMake(CGRectGetMaxX(innerFrame) - innerRadius, CGRectGetMaxY(innerFrame) - innerRadius) radius:innerRadius startAngle:M_PI / 2 endAngle:0.0f clockwise:NO]; // bottom-right corner
        [innerStrokePath addLineToPoint: CGPointMake(CGRectGetMaxX(innerFrame), CGRectGetMinY(innerFrame) + innerRadius)]; // right
        [innerStrokePath addArcWithCenter:CGPointMake(CGRectGetMaxX(innerFrame) - innerRadius, CGRectGetMinY(innerFrame) + innerRadius) radius:innerRadius startAngle:0.0f endAngle:-M_PI / 2 clockwise:NO]; // top-right corner
        
        // pointer up
        if (pointingUp) {
            [innerStrokePath addLineToPoint:CGPointMake(CGRectGetMaxX(anchorInnerRect), CGRectGetMinY(innerFrame))];
            [innerStrokePath addLineToPoint:CGPointMake(CGRectGetMinX(anchorInnerRect) + anchorRect.size.width / 2, CGRectGetMinY(innerFrame) - anchorInnerRect.size.height)];
            [innerStrokePath addLineToPoint:CGPointMake(CGRectGetMinX(anchorInnerRect), CGRectGetMinY(innerFrame))];
        }
        
        [innerStrokePath addLineToPoint:CGPointMake(CGRectGetMinX(innerFrame) + innerRadius, CGRectGetMinY(innerFrame))]; // top
        [innerStrokePath addArcWithCenter:CGPointMake(CGRectGetMinX(innerFrame) + innerRadius, CGRectGetMinY(innerFrame) + innerRadius) radius:innerRadius startAngle:-M_PI / 2 endAngle:M_PI clockwise:NO]; // top-left corner
        [innerStrokePath closePath];
        
        [innerStrokeColor setStroke];
        innerStrokePath.lineWidth = backgroundStrokeWidth;
        [innerStrokePath stroke];
        
        
        //// GlossGroup ////
        {
            CGContextSaveGState(context);
            CGContextSetAlpha(context, 0.45);
            CGContextBeginTransparencyLayer(context, NULL);
            
            CGFloat glossRadius = radius + 0.5;
            
            // Gloss Drawing
            UIBezierPath* glossPath = [UIBezierPath bezierPath];
            [glossPath moveToPoint:CGPointMake(CGRectGetMinX(glossFrame), CGRectGetMinY(glossFrame))];
            [glossPath addLineToPoint:CGPointMake(CGRectGetMinX(glossFrame), CGRectGetMaxY(glossFrame) - glossRadius)]; // left
            [glossPath addArcWithCenter:CGPointMake(CGRectGetMinX(glossFrame) + glossRadius, CGRectGetMaxY(glossFrame) - glossRadius) radius:glossRadius startAngle:M_PI endAngle:M_PI / 2 clockwise:NO]; // bottom-left corner
            [glossPath addLineToPoint:CGPointMake(CGRectGetMaxX(glossFrame) - glossRadius, CGRectGetMaxY(glossFrame))]; // bottom
            [glossPath addArcWithCenter:CGPointMake(CGRectGetMaxX(glossFrame) - glossRadius, CGRectGetMaxY(glossFrame) - glossRadius) radius:glossRadius startAngle:M_PI / 2 endAngle:0.0f clockwise:NO]; // bottom-right corner
            [glossPath addLineToPoint: CGPointMake(CGRectGetMaxX(glossFrame), CGRectGetMinY(glossFrame) - glossRadius)]; // right
            [glossPath addArcWithCenter:CGPointMake(CGRectGetMaxX(glossFrame) - glossRadius, CGRectGetMinY(glossFrame) + glossRadius) radius:glossRadius startAngle:0.0f endAngle:-M_PI / 2 clockwise:NO]; // top-right corner
            
            // pointer up
            if (pointingUp) {
                [glossPath addLineToPoint:CGPointMake(CGRectGetMaxX(anchorRect), CGRectGetMinY(glossFrame))];
                [glossPath addLineToPoint:CGPointMake(CGRectGetMinX(anchorRect) + roundf(anchorRect.size.width / 2), CGRectGetMinY(glossFrame) - anchorRect.size.height)];
                [glossPath addLineToPoint:CGPointMake(CGRectGetMinX(anchorRect), CGRectGetMinY(glossFrame))];
            }
            
            [glossPath addLineToPoint:CGPointMake(CGRectGetMinX(glossFrame) + glossRadius, CGRectGetMinY(glossFrame))]; // top
            [glossPath addArcWithCenter:CGPointMake(CGRectGetMinX(glossFrame) + glossRadius, CGRectGetMinY(glossFrame) + glossRadius) radius:glossRadius startAngle:-M_PI / 2 endAngle:M_PI clockwise:NO]; // top-left corner
            [glossPath closePath];
            
            CGContextSaveGState(context);
            [glossPath addClip];
            CGRect glossBounds = glossPath.bounds;
            CGContextDrawLinearGradient(context, glossFill,
                                        CGPointMake(CGRectGetMidX(glossBounds), CGRectGetMaxY(glossBounds)),
                                        CGPointMake(CGRectGetMidX(glossBounds), CGRectGetMinY(glossBounds)),
                                        0);
            CGContextRestoreGState(context);
            
            CGContextEndTransparencyLayer(context);
            CGContextRestoreGState(context);
        }
        
        CGContextEndTransparencyLayer(context);
        CGContextRestoreGState(context);
    }
    
    // Outer Stroke Drawing
    UIBezierPath* outerStrokePath = [UIBezierPath bezierPath];
    [outerStrokePath moveToPoint:CGPointMake(CGRectGetMinX(frame), CGRectGetMinY(frame) + radius)];
    [outerStrokePath addLineToPoint:CGPointMake(CGRectGetMinX(frame), CGRectGetMaxY(frame) - radius)]; // left
    [outerStrokePath addArcWithCenter:CGPointMake(CGRectGetMinX(frame) + radius, CGRectGetMaxY(frame) - radius) radius:radius startAngle:M_PI endAngle:M_PI / 2 clockwise:NO]; // bottom-left corner
    
    // pointer down
    if (!pointingUp) {
        [outerStrokePath addLineToPoint:CGPointMake(CGRectGetMinX(anchorRect), CGRectGetMaxY(frame))];
        [outerStrokePath addLineToPoint:CGPointMake(CGRectGetMinX(anchorRect) + anchorRect.size.width / 2, CGRectGetMaxY(frame) + anchorRect.size.height)];
        [outerStrokePath addLineToPoint:CGPointMake(CGRectGetMaxX(anchorRect), CGRectGetMaxY(frame))];
    }
    
    [outerStrokePath addLineToPoint:CGPointMake(CGRectGetMaxX(frame) - radius, CGRectGetMaxY(frame))]; // bottom
    [outerStrokePath addArcWithCenter:CGPointMake(CGRectGetMaxX(frame) - radius, CGRectGetMaxY(frame) - radius) radius:radius startAngle:M_PI / 2 endAngle:0.0f clockwise:NO]; // bottom-right corner
    [outerStrokePath addLineToPoint: CGPointMake(CGRectGetMaxX(frame), CGRectGetMinY(frame) + radius)]; // right
    [outerStrokePath addArcWithCenter:CGPointMake(CGRectGetMaxX(frame) - radius, CGRectGetMinY(frame) + radius) radius:radius startAngle:0.0f endAngle:-M_PI / 2 clockwise:NO]; // top-right corner
    
    // pointer up
    if (pointingUp) {
        [outerStrokePath addLineToPoint:CGPointMake(CGRectGetMaxX(anchorRect), CGRectGetMinY(frame))];
        [outerStrokePath addLineToPoint:CGPointMake(CGRectGetMinX(anchorRect) + anchorRect.size.width / 2, CGRectGetMinY(frame) - anchorRect.size.height)];
        [outerStrokePath addLineToPoint:CGPointMake(CGRectGetMinX(anchorRect), CGRectGetMinY(frame))];
    }
    
    [outerStrokePath addLineToPoint:CGPointMake(CGRectGetMinX(frame) + radius, CGRectGetMinY(frame))]; // top
    [outerStrokePath addArcWithCenter:CGPointMake(CGRectGetMinX(frame) + radius, CGRectGetMinY(frame) + radius) radius:radius startAngle:-M_PI / 2 endAngle:M_PI clockwise:NO]; // top-left corner
    [outerStrokePath closePath];
    CGContextSaveGState(context);
    CGContextSetShadowWithColor(context, baseShadowOffset, baseShadowBlurRadius, baseShadow.CGColor);
    CGContextRestoreGState(context);
    
    [outerStrokeColor setStroke];
    outerStrokePath.lineWidth = outerStrokeStrokeWidth;
    [outerStrokePath stroke];
    
    //// Cleanup
    CGGradientRelease(glossFill);
    CGColorSpaceRelease(colorSpace);
}

@end

//
// Our UIView frame helpers implementation
//

@implementation UIView (SMFrameAdditions)

- (CGPoint)$origin { return self.frame.origin; }
- (void)set$origin:(CGPoint)origin { self.frame = (CGRect){ .origin=origin, .size=self.frame.size }; }

- (CGFloat)$x { return self.frame.origin.x; }
- (void)set$x:(CGFloat)x { self.frame = (CGRect){ .origin.x=x, .origin.y=self.frame.origin.y, .size=self.frame.size }; }

- (CGFloat)$y { return self.frame.origin.y; }
- (void)set$y:(CGFloat)y { self.frame = (CGRect){ .origin.x=self.frame.origin.x, .origin.y=y, .size=self.frame.size }; }

- (CGSize)$size { return self.frame.size; }
- (void)set$size:(CGSize)size { self.frame = (CGRect){ .origin=self.frame.origin, .size=size }; }

- (CGFloat)$width { return self.frame.size.width; }
- (void)set$width:(CGFloat)width { self.frame = (CGRect){ .origin=self.frame.origin, .size.width=width, .size.height=self.frame.size.height }; }

- (CGFloat)$height { return self.frame.size.height; }
- (void)set$height:(CGFloat)height { self.frame = (CGRect){ .origin=self.frame.origin, .size.width=self.frame.size.width, .size.height=height }; }

- (CGFloat)$left { return self.frame.origin.x; }
- (void)set$left:(CGFloat)left { self.frame = (CGRect){ .origin.x=left, .origin.y=self.frame.origin.y, .size.width=fmaxf(self.frame.origin.x+self.frame.size.width-left,0), .size.height=self.frame.size.height }; }

- (CGFloat)$top { return self.frame.origin.y; }
- (void)set$top:(CGFloat)top { self.frame = (CGRect){ .origin.x=self.frame.origin.x, .origin.y=top, .size.width=self.frame.size.width, .size.height=fmaxf(self.frame.origin.y+self.frame.size.height-top,0) }; }

- (CGFloat)$right { return self.frame.origin.x + self.frame.size.width; }
- (void)set$right:(CGFloat)right { self.frame = (CGRect){ .origin=self.frame.origin, .size.width=fmaxf(right-self.frame.origin.x,0), .size.height=self.frame.size.height }; }

- (CGFloat)$bottom { return self.frame.origin.y + self.frame.size.height; }
- (void)set$bottom:(CGFloat)bottom { self.frame = (CGRect){ .origin=self.frame.origin, .size.width=self.frame.size.width, .size.height=fmaxf(bottom-self.frame.origin.y,0) }; }

@end
