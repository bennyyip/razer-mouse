package main

import win32 "core:sys/windows"

HDEVINFO :: distinct win32.HANDLE

SP_DEVINFO_DATA :: struct {
	cbSize:    win32.DWORD,
	ClassGuid: win32.GUID,
	DevInst:   win32.DWORD,
	Reserved:  win32.ULONG_PTR,
}
PSP_DEVINFO_DATA :: ^SP_DEVINFO_DATA

SP_DEVICE_INTERFACE_DATA :: struct {
	cbSize:             win32.DWORD,
	InterfaceClassGuid: win32.GUID,
	Flags:              win32.DWORD,
	Reserved:           win32.ULONG_PTR,
}
PSP_DEVICE_INTERFACE_DATA :: ^SP_DEVICE_INTERFACE_DATA

SP_DEVICE_INTERFACE_DETAIL_DATA_W :: struct {
	cbSize:     win32.DWORD,
	DevicePath: [win32.ANYSIZE_ARRAY]win32.WCHAR,
}
PSP_DEVICE_INTERFACE_DETAIL_DATA_W :: ^SP_DEVICE_INTERFACE_DETAIL_DATA_W

DIGCF_DEFAULT :: 0x00000001
DIGCF_PRESENT :: 0x00000002
DIGCF_ALLCLASSES :: 0x00000004
DIGCF_PROFILE :: 0x00000008
DIGCF_DEVICEINTERFACE :: 0x00000010

foreign import setupapi "system:setupapi.lib"
@(default_calling_convention = "system")
foreign setupapi {
	SetupDiGetClassDevsW :: proc(ClassGuid: ^win32.GUID, Enumerator: win32.PCWSTR, hwndParent: win32.HWND, Flags: win32.DWORD) -> HDEVINFO ---
	SetupDiEnumDeviceInterfaces :: proc(DeviceInfoSet: HDEVINFO, DeviceInfoData: PSP_DEVINFO_DATA, GUID: ^win32.GUID, MemberIndex: win32.DWORD, DeviceInterfaceData: PSP_DEVICE_INTERFACE_DATA) -> win32.BOOL ---
	SetupDiGetDeviceInterfaceDetailW :: proc(DeviceInfoSet: HDEVINFO, DeviceInterfaceData: PSP_DEVICE_INTERFACE_DATA, DeviceInterfaceDetailData: PSP_DEVICE_INTERFACE_DETAIL_DATA_W, DeviceInterfaceDetailDataSize: win32.DWORD, RequiredSize: win32.PDWORD, DeviceInfoData: PSP_DEVINFO_DATA) -> win32.BOOL ---
	SetupDiDestroyDeviceInfoList :: proc(DeviceInfoSet: HDEVINFO) -> win32.BOOL ---
}
