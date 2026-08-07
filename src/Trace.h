// Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
// Licensed under the Microsoft Public License (MS-PL).

#pragma once

#include <windows.h>
#include <strsafe.h>
#include <stdarg.h>

inline void DlxTrace(_In_z_ const char* Level, _In_z_ _Printf_format_string_ const char* Format, ...)
{
    char message[768] = {};
    char body[640] = {};

    va_list arguments;
    va_start(arguments, Format);
    (void)StringCchVPrintfA(body, ARRAYSIZE(body), Format, arguments);
    va_end(arguments);

    (void)StringCchPrintfA(message, ARRAYSIZE(message), "[DeckLux][%s] %s\r\n", Level, body);
    OutputDebugStringA(message);
}

#define DLX_TRACE_ERROR(...) DlxTrace("error", __VA_ARGS__)
#define DLX_TRACE_WARNING(...) DlxTrace("warning", __VA_ARGS__)
#define DLX_TRACE_INFO(...) DlxTrace("info", __VA_ARGS__)
