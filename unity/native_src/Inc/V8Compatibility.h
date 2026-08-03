#pragma once

#include <cstdint>
#include <cstdlib>

#include "v8.h"

#define PUERTS_V8_VERSION_AT_LEAST(Major, Minor) \
    (V8_MAJOR_VERSION > (Major) || (V8_MAJOR_VERSION == (Major) && V8_MINOR_VERSION >= (Minor)))

#define PUERTS_V8_129_OR_NEWER PUERTS_V8_VERSION_AT_LEAST(12, 9)
#define PUERTS_V8_138_OR_NEWER PUERTS_V8_VERSION_AT_LEAST(13, 8)
#define PUERTS_V8_149_OR_NEWER PUERTS_V8_VERSION_AT_LEAST(14, 9)

namespace puerts_v8_compatibility
{
enum class ExternalPointerTag : uint16_t
{
    CppObjectMapper = 1,
    PesapiCallbackData = 2,
    JSClassDefinition = 3,
    CSharpCallbackInfo = 4,
    LifeCycleInfo = 5,
    NativeConstructorArgument = 6,
    NativePrivateData = 7,
    ModuleResolutionData = 8,
};

enum class EmbedderDataTag : uint16_t
{
    NativeObject = 1,
    LifeCycleInfo = 2,
    ObjectMagic = 3,
    SplitPointerHigh = 4,
    SplitPointerLow = 5,
    WebSocketClient = 6,
};

#if PUERTS_V8_149_OR_NEWER
static_assert(static_cast<uint16_t>(ExternalPointerTag::ModuleResolutionData) <
        V8_EXTERNAL_POINTER_TAG_COUNT - 1,
    "PuerTS External tag 不得占用 V8 Fast API 保留的最后一个 tag");
static_assert(static_cast<uint16_t>(EmbedderDataTag::WebSocketClient) < V8_EMBEDDER_DATA_TAG_COUNT,
    "PuerTS Embedder Data tag 超出 V8 14.9 支持范围");
#endif

inline v8::Local<v8::External> NewExternal(
    v8::Isolate* Isolate, void* Pointer, ExternalPointerTag Tag)
{
#if PUERTS_V8_149_OR_NEWER
    return v8::External::New(Isolate, Pointer, static_cast<v8::ExternalPointerTypeTag>(Tag));
#else
    static_cast<void>(Tag);
    return v8::External::New(Isolate, Pointer);
#endif
}

inline void* GetExternalValue(v8::Local<v8::External> External, ExternalPointerTag Tag)
{
#if PUERTS_V8_149_OR_NEWER
    return External->Value(static_cast<v8::ExternalPointerTypeTag>(Tag));
#else
    static_cast<void>(Tag);
    return External->Value();
#endif
}

inline void SetAlignedPointerInInternalField(
    v8::Local<v8::Object> Object, int Index, void* Pointer, EmbedderDataTag Tag)
{
#if PUERTS_V8_149_OR_NEWER
    Object->SetAlignedPointerInInternalField(
        Index, Pointer, static_cast<v8::EmbedderDataTypeTag>(Tag));
#else
    static_cast<void>(Tag);
    Object->SetAlignedPointerInInternalField(Index, Pointer);
#endif
}

inline void SetAlignedPointerInInternalField(
    v8::Object* Object, int Index, void* Pointer, EmbedderDataTag Tag)
{
#if PUERTS_V8_149_OR_NEWER
    Object->SetAlignedPointerInInternalField(
        Index, Pointer, static_cast<v8::EmbedderDataTypeTag>(Tag));
#else
    static_cast<void>(Tag);
    Object->SetAlignedPointerInInternalField(Index, Pointer);
#endif
}

inline void* GetAlignedPointerFromInternalField(
    v8::Local<v8::Object> Object, int Index, EmbedderDataTag Tag)
{
#if PUERTS_V8_149_OR_NEWER
    return Object->GetAlignedPointerFromInternalField(
        Index, static_cast<v8::EmbedderDataTypeTag>(Tag));
#else
    static_cast<void>(Tag);
    return Object->GetAlignedPointerFromInternalField(Index);
#endif
}

inline v8::Isolate* GetIsolate(v8::Local<v8::Context> Context)
{
#if PUERTS_V8_149_OR_NEWER
    static_cast<void>(Context);
    return v8::Isolate::GetCurrent();
#else
    return Context->GetIsolate();
#endif
}

inline void* GetArrayBufferData(v8::Local<v8::ArrayBuffer> ArrayBuffer, size_t& ByteLength)
{
#if defined(HAS_ARRAYBUFFER_NEW_WITHOUT_STL)
    return v8::ArrayBuffer_Get_Data(ArrayBuffer, ByteLength);
#else
    auto BackingStore = ArrayBuffer->GetBackingStore();
    ByteLength = BackingStore->ByteLength();
    return BackingStore->Data();
#endif
}

inline void* RequireArrayBufferData(v8::Local<v8::ArrayBuffer> ArrayBuffer, size_t RequiredLength)
{
    size_t ByteLength = 0;
    void* Data = GetArrayBufferData(ArrayBuffer, ByteLength);
    if ((RequiredLength > 0 && Data == nullptr) || ByteLength < RequiredLength)
    {
        std::abort();
    }
    return Data;
}

inline size_t Utf8Length(v8::Local<v8::String> String, v8::Isolate* Isolate)
{
#if PUERTS_V8_149_OR_NEWER
    return String->Utf8LengthV2(Isolate);
#else
    return static_cast<size_t>(String->Utf8Length(Isolate));
#endif
}

// 精确容量只容纳 UTF-8 正文；强制空终止会占用最后一个正文字节。
inline size_t WriteUtf8Bytes(
    v8::Local<v8::String> String, v8::Isolate* Isolate, char* Buffer, size_t Capacity)
{
#if PUERTS_V8_149_OR_NEWER
    return String->WriteUtf8V2(Isolate, Buffer, Capacity, v8::String::WriteFlags::kNone);
#else
    return static_cast<size_t>(String->WriteUtf8(
        Isolate, Buffer, static_cast<int>(Capacity), nullptr, v8::String::NO_NULL_TERMINATION));
#endif
}

// C 字符串调用方必须提供 Utf8Length(String) + 1 字节容量。
inline size_t WriteUtf8CString(
    v8::Local<v8::String> String, v8::Isolate* Isolate, char* Buffer, size_t Capacity)
{
#if PUERTS_V8_149_OR_NEWER
    return String->WriteUtf8V2(
        Isolate, Buffer, Capacity, v8::String::WriteFlags::kNullTerminate);
#else
    return static_cast<size_t>(String->WriteUtf8(
        Isolate, Buffer, static_cast<int>(Capacity), nullptr, v8::String::NO_OPTIONS));
#endif
}

inline void WriteTwoByte(v8::Local<v8::String> String, v8::Isolate* Isolate,
    uint16_t* Buffer, size_t Length)
{
#if PUERTS_V8_149_OR_NEWER
    String->WriteV2(Isolate, 0, static_cast<uint32_t>(Length), Buffer);
#else
    String->Write(
        Isolate, Buffer, 0, static_cast<int>(Length), v8::String::NO_OPTIONS);
#endif
}

inline auto GetFixedArrayElement(
    v8::Local<v8::FixedArray> Array, v8::Local<v8::Context> Context, int Index)
{
#if PUERTS_V8_149_OR_NEWER
    static_cast<void>(Context);
    return Array->Get(Index);
#else
    return Array->Get(Context, Index);
#endif
}

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
