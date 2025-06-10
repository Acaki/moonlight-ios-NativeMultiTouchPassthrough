//
//  Logger.h
//  Moonlight
//
//  Created by Diego Waxemberg on 2/10/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#ifndef Limelight_Logger_h
#define Limelight_Logger_h

#import <dispatch/dispatch.h>
#import <stdarg.h>

typedef enum {
    LOG_D,
    LOG_I,
    LOG_W,
    LOG_E
} LogLevel;

#define PRFX_DEBUG @"<DEBUG>"
#define PRFX_INFO @"<INFO>"
#define PRFX_WARN @"<WARN>"
#define PRFX_ERROR @"<ERROR>"

void Log(LogLevel level, NSString* fmt, ...);
void LogTag(LogLevel level, NSString* tag, NSString* fmt, ...);

// LogOnce() is a one-time log message for use in hot areas of the code
#define CONCAT(a,b)   CONCAT2(a,b)
#define CONCAT2(a,b)  a##b

#define LogOnce(level, fmt, ...)                                    \
  do {                                                              \
    static dispatch_once_t CONCAT(_onceToken_, __LINE__);           \
    dispatch_once(&CONCAT(_onceToken_, __LINE__), ^{                \
      Log(level, fmt, ##__VA_ARGS__);                               \
    });                                                             \
  } while (0)

#endif
