//
//  LegacyUSBShim.c
//  macOS 12 及更早的 SysDVR USB 通道。
//  这些系统上设备挂在老的 IOKit USB 栈（AppleUSBDevice / IOUSBInterface），
//  系统不会发布 IOUSBHostInterface，只能通过 IOUSBLib 的 CFPlugIn 接口访问。
//  Swift 直接调这些 vtable 容易踩调用约定的坑，所以这里用 C 封装成 4 个函数。
//

#include "LegacyUSBShim.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <string.h>
#include <stdlib.h>

#define SC_VID 0x18D1
#define SC_PID 0x4EE0

typedef struct {
    IOUSBDeviceInterface **dev;
    IOUSBInterfaceInterface **intf;
    UInt8 inPipe;
    UInt8 outPipe;
    char serial[160];
    IOReturn lastStatus;   // 最近一次 IO 的原始 IOReturn，便于诊断
} sc_usb_t;

static int sc_serial_for_service(io_service_t service, char *out, size_t len)
{
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("USB Serial Number"),
                                                      kCFAllocatorDefault, 0);
    if (!value) return -1;
    int ok = -1;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        if (CFStringGetCString((CFStringRef)value, out, (CFIndex)len, kCFStringEncodingUTF8)) ok = 0;
    }
    CFRelease(value);
    return ok;
}

void *sc_usb_open(const char *serial_prefix, int *out_err)
{
    if (out_err) *out_err = SC_USB_ERR_NOT_FOUND;

    CFMutableDictionaryRef match = IOServiceMatching("IOUSBDevice");
    if (!match) return NULL;
    int vid = SC_VID, pid = SC_PID;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR("idVendor"), v);
    CFDictionarySetValue(match, CFSTR("idProduct"), p);
    CFRelease(v);
    CFRelease(p);

    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) != KERN_SUCCESS) return NULL;

    io_service_t service = 0;
    char serial[160] = {0};
    size_t prefix_len = serial_prefix ? strlen(serial_prefix) : 0;
    while ((service = IOIteratorNext(iterator)) != 0) {
        if (sc_serial_for_service(service, serial, sizeof(serial)) == 0 &&
            (prefix_len == 0 || strncmp(serial, serial_prefix, prefix_len) == 0)) {
            break;
        }
        IOObjectRelease(service);
        service = 0;
    }
    IOObjectRelease(iterator);
    if (service == 0) return NULL;

    sc_usb_t *handle = calloc(1, sizeof(sc_usb_t));
    if (!handle) { IOObjectRelease(service); return NULL; }
    strncpy(handle->serial, serial, sizeof(handle->serial) - 1);

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                                        kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != KERN_SUCCESS || !plug) {
        if (out_err) *out_err = SC_USB_ERR_OPEN;
        free(handle); IOObjectRelease(service); return NULL;
    }
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                         (LPVOID *)&handle->dev);
    (*plug)->Release(plug);
    if (hr != S_OK || !handle->dev) {
        if (out_err) *out_err = SC_USB_ERR_OPEN;
        free(handle); IOObjectRelease(service); return NULL;
    }

    // 先 Seize（强制独占，libusb 在 macOS 上就是这么干的），拿不到再退回普通 open。
    // 少了这一步，设备虽然能"打开"，但接口仍被 AppleUSBHostLegacyClient 占着，
    // 后续 bulk 写会返回 kIOReturnNotPermitted (0xE00002ED)。
    IOReturn openResult = (*handle->dev)->USBDeviceOpenSeize(handle->dev);
    if (openResult != kIOReturnSuccess) {
        openResult = (*handle->dev)->USBDeviceOpen(handle->dev);
    }
    if (openResult != kIOReturnSuccess) {
        if (out_err) *out_err = SC_USB_ERR_BUSY;
        (*handle->dev)->Release(handle->dev);
        free(handle); IOObjectRelease(service); return NULL;
    }

    IOUSBFindInterfaceRequest request = {
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
        kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare
    };
    io_iterator_t interfaces = 0;
    (*handle->dev)->CreateInterfaceIterator(handle->dev, &request, &interfaces);
    io_service_t interfaceService = IOIteratorNext(interfaces);

    if (interfaceService == 0) {
        // 设备还没被配置过时，接口节点不会出现，主动下发一次 SET_CONFIGURATION
        (*handle->dev)->SetConfiguration(handle->dev, 1);
        usleep(500000);
        if (interfaces) IOObjectRelease(interfaces);
        (*handle->dev)->CreateInterfaceIterator(handle->dev, &request, &interfaces);
        interfaceService = IOIteratorNext(interfaces);
    }
    if (interfaces) IOObjectRelease(interfaces);

    if (interfaceService == 0) {
        if (out_err) *out_err = SC_USB_ERR_NO_INTERFACE;
        (*handle->dev)->USBDeviceClose(handle->dev);
        (*handle->dev)->Release(handle->dev);
        free(handle); IOObjectRelease(service); return NULL;
    }

    IOCFPlugInInterface **iplug = NULL;
    kr = IOCreatePlugInInterfaceForService(interfaceService, kIOUSBInterfaceUserClientTypeID,
                                           kIOCFPlugInInterfaceID, &iplug, &score);
    IOObjectRelease(interfaceService);
    if (kr != KERN_SUCCESS || !iplug) {
        if (out_err) *out_err = SC_USB_ERR_NO_INTERFACE;
        (*handle->dev)->USBDeviceClose(handle->dev);
        (*handle->dev)->Release(handle->dev);
        free(handle); IOObjectRelease(service); return NULL;
    }
    hr = (*iplug)->QueryInterface(iplug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID),
                                  (LPVOID *)&handle->intf);
    (*iplug)->Release(iplug);
    if (hr != S_OK || !handle->intf) {
        if (out_err) *out_err = SC_USB_ERR_NO_INTERFACE;
        (*handle->dev)->USBDeviceClose(handle->dev);
        (*handle->dev)->Release(handle->dev);
        free(handle); IOObjectRelease(service); return NULL;
    }

    // 接口同样先 Seize：macOS 12 上接口默认归 AppleUSBHostLegacyClient，
    // 不夺权的话 USBInterfaceOpen 能成功但读写都会被拒。
    IOReturn intfResult = (*handle->intf)->USBInterfaceOpenSeize(handle->intf);
    if (intfResult != kIOReturnSuccess) {
        intfResult = (*handle->intf)->USBInterfaceOpen(handle->intf);
    }
    if (intfResult != kIOReturnSuccess) {
        if (out_err) *out_err = SC_USB_ERR_BUSY;
        (*handle->intf)->Release(handle->intf);
        (*handle->dev)->USBDeviceClose(handle->dev);
        (*handle->dev)->Release(handle->dev);
        free(handle); IOObjectRelease(service); return NULL;
    }

    UInt8 endpointCount = 0;
    (*handle->intf)->GetNumEndpoints(handle->intf, &endpointCount);
    for (UInt8 index = 1; index <= endpointCount; index++) {
        UInt8 direction = 0, number = 0, type = 0, interval = 0;
        UInt16 maxPacket = 0;
        (*handle->intf)->GetPipeProperties(handle->intf, index, &direction, &number,
                                           &type, &maxPacket, &interval);
        if (type != kUSBBulk) continue;
        if (direction == kUSBIn && handle->inPipe == 0) handle->inPipe = index;
        if (direction == kUSBOut && handle->outPipe == 0) handle->outPipe = index;
    }

    if (handle->inPipe == 0 || handle->outPipe == 0) {
        if (out_err) *out_err = SC_USB_ERR_NO_ENDPOINT;
        (*handle->intf)->USBInterfaceClose(handle->intf);
        (*handle->intf)->Release(handle->intf);
        (*handle->dev)->USBDeviceClose(handle->dev);
        (*handle->dev)->Release(handle->dev);
        free(handle); IOObjectRelease(service); return NULL;
    }

    IOObjectRelease(service);

    // 上一个客户端异常退出可能留下 stall，清一次再开始
    (*handle->intf)->ClearPipeStallBothEnds(handle->intf, handle->inPipe);
    (*handle->intf)->ClearPipeStallBothEnds(handle->intf, handle->outPipe);

    if (out_err) *out_err = SC_USB_OK;
    return handle;
}

int sc_usb_read(void *opaque, void *buffer, int length, int timeout_ms)
{
    sc_usb_t *handle = (sc_usb_t *)opaque;
    if (!handle || !handle->intf) return SC_USB_ERR_CLOSED;
    UInt32 size = (UInt32)length;
    IOReturn kr = (*handle->intf)->ReadPipeTO(handle->intf, handle->inPipe, buffer, &size, 0,
                                              (UInt32)timeout_ms);
    handle->lastStatus = kr;
    if (kr == kIOReturnSuccess) return (int)size;
    if (kr == kIOReturnTimeout || kr == (IOReturn)0xE0004061) return SC_USB_ERR_TIMEOUT;
    return SC_USB_ERR_IO;
}

int sc_usb_write(void *opaque, const void *buffer, int length)
{
    sc_usb_t *handle = (sc_usb_t *)opaque;
    if (!handle || !handle->intf) return SC_USB_ERR_CLOSED;
    IOReturn kr = (*handle->intf)->WritePipeTO(handle->intf, handle->outPipe, (void *)buffer,
                                               (UInt32)length, 0, 2000);
    handle->lastStatus = kr;
    return kr == kIOReturnSuccess ? length : SC_USB_ERR_IO;
}

void sc_usb_close(void *opaque)
{
    sc_usb_t *handle = (sc_usb_t *)opaque;
    if (!handle) return;
    if (handle->intf) {
        (*handle->intf)->USBInterfaceClose(handle->intf);
        (*handle->intf)->Release(handle->intf);
    }
    if (handle->dev) {
        (*handle->dev)->USBDeviceClose(handle->dev);
        (*handle->dev)->Release(handle->dev);
    }
    free(handle);
}

int sc_usb_serial(void *opaque, char *out, int length)
{
    sc_usb_t *handle = (sc_usb_t *)opaque;
    if (!handle || !out || length <= 0) return -1;
    strncpy(out, handle->serial, (size_t)length - 1);
    out[length - 1] = 0;
    return 0;
}

/// 最近一次 IO 的原始 IOReturn（0 表示成功）
unsigned int sc_usb_last_status(void *opaque)
{
    sc_usb_t *handle = (sc_usb_t *)opaque;
    return handle ? (unsigned int)handle->lastStatus : 0;
}

int sc_usb_available(void)
{
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBDevice");
    if (!match) return 0;
    int vid = SC_VID, pid = SC_PID;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR("idVendor"), v);
    CFDictionarySetValue(match, CFSTR("idProduct"), p);
    CFRelease(v); CFRelease(p);

    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) != KERN_SUCCESS) return 0;
    int found = 0;
    io_service_t service = 0;
    char serial[160];
    while ((service = IOIteratorNext(iterator)) != 0) {
        if (sc_serial_for_service(service, serial, sizeof(serial)) == 0 &&
            strncmp(serial, "SysDVR|", 7) == 0) { found = 1; }
        IOObjectRelease(service);
        if (found) break;
    }
    IOObjectRelease(iterator);
    return found;
}
