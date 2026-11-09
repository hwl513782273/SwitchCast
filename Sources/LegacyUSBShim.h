#ifndef LegacyUSBShim_h
#define LegacyUSBShim_h

#include <stddef.h>

/// 错误码
enum {
    SC_USB_OK = 0,
    SC_USB_ERR_NOT_FOUND = -1,
    SC_USB_ERR_OPEN = -2,
    SC_USB_ERR_BUSY = -3,
    SC_USB_ERR_NO_INTERFACE = -4,
    SC_USB_ERR_NO_ENDPOINT = -5,
    SC_USB_ERR_IO = -6,
    SC_USB_ERR_TIMEOUT = -7,
    SC_USB_ERR_CLOSED = -8
};

/// 打开第一个序列号以 serial_prefix 开头的 SysDVR 设备（传 NULL 表示不校验）。
/// 返回不透明句柄，失败返回 NULL 并把原因写进 out_err。
void *sc_usb_open(const char *serial_prefix, int *out_err);

/// 读一包数据，返回字节数；超时返回 SC_USB_ERR_TIMEOUT，其它错误返回负值。
int sc_usb_read(void *handle, void *buffer, int length, int timeout_ms);

/// 写一段数据，返回写入字节数，失败返回负值。
int sc_usb_write(void *handle, const void *buffer, int length);

/// 关闭并释放句柄。
void sc_usb_close(void *handle);

/// 取出设备序列号，返回 0 表示成功。
int sc_usb_serial(void *handle, char *out, int length);

/// 最近一次 IO 的原始 IOReturn（0 表示成功），用于错误诊断。
unsigned int sc_usb_last_status(void *handle);

/// 老栈上是否存在 SysDVR 设备（只读，不打开）。
int sc_usb_available(void);

#endif /* LegacyUSBShim_h */
