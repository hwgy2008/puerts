#pragma once

#include "v8.h"

#define PUERTS_V8_VERSION_AT_LEAST(Major, Minor) \
    (V8_MAJOR_VERSION > (Major) || (V8_MAJOR_VERSION == (Major) && V8_MINOR_VERSION >= (Minor)))

#define PUERTS_V8_129_OR_NEWER PUERTS_V8_VERSION_AT_LEAST(12, 9)
#define PUERTS_V8_138_OR_NEWER PUERTS_V8_VERSION_AT_LEAST(13, 8)

namespace puerts_v8_compatibility
{
template <typename T>
v8::Local<v8::Object> GetFunctionCallbackHolder(const v8::FunctionCallbackInfo<T>& Info)
{
#if PUERTS_V8_138_OR_NEWER
    return Info.This();
#else
    return Info.Holder();
#endif
}
}
