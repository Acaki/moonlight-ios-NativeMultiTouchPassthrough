//
//  RelativeTouchHandler.h
//  Moonlight
//
//  Created by Cameron Gutman on 11/1/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

#import "StreamView.h"

NS_ASSUME_NONNULL_BEGIN

@interface RelativeTouchHandler : UIResponder

#if TARGET_OS_TV
@property (nonatomic) UIGestureRecognizer* remotePressRecognizer;
@property (nonatomic) UIGestureRecognizer* remoteLongPressRecognizer;
#endif

-(id)initWithView:(StreamView*)view;

@end

NS_ASSUME_NONNULL_END
