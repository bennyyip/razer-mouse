package main
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import win32 "core:sys/windows"
import "core:time"

// mouse vid and pid can be found here:
// https://github.com/openrazer/openrazer#mice
Mouse :: struct {
	vid: u16,
	pid: u16,
}

Razer_DeathAdder_V2_X_HyperSpeed: Mouse = {0x1532, 0x9c}

Device :: struct {
	handle: win32.HANDLE,
}

Razer_Status :: enum u8 {
	NEW_COMMAND                    = 0,
	COMMAND_BUSY                   = 1,
	COMMAND_SUCCESSFUL             = 2,
	COMMAND_FAILURE                = 3,
	COMMAND_NO_RESPONSE_OR_TIMEOUT = 4,
	COMMAND_NOT_SUPPORT            = 5,
}

/*
 * Transaction ID used to group request-response, device useful when multiple devices are on one usb
 * Remaining Packets is the number of remaining packets in the sequence
 * Protocol Type is always 0x00
 * Data Size is the size of payload, cannot be greater than 80. 90 = header (8B) + data + CRC (1B) + Reserved (1B)
 * Command Class is the type of command being issued
 * Command ID is the type of command being send. Direction 0 is Host->Device, Direction 1 is Device->Host. AKA Get LED 0x80, Set LED 0x00
 *
 * */

Razer_Report :: struct {
	status:            Razer_Status,
	transaction_id:    bit_field u8 {
		device: u8 | 3,
		id:     u8 | 5,
	},
	remaining_packets: u16be,
	protocol_type:     u8,
	data_size:         u8,
	command_class:     u8,
	command_id:        u8,
	arguments:         [80]u8 `fmt:"-"`,
	crc:               u8,
	reserved:          u8,
}
REPORT_SIZE :: size_of(Razer_Report)
HIDBUF_SIZE :: REPORT_SIZE + 1
#assert(REPORT_SIZE == 90)

NOTSTORE :: 0
VARSTORE :: 1

RAZER_MOUSE_MAX_DPI_STAGES :: 5

find_mouse_device :: proc(mouse: Mouse) -> (_dev: Device, _ok: bool) {
	guid: win32.GUID
	win32.HidD_GetHidGuid(&guid)
	set := win32.SetupDiGetClassDevsW(
		&guid,
		nil,
		nil,
		win32.DIGCF_PRESENT | win32.DIGCF_DEVICEINTERFACE,
	)
	if (win32.HANDLE(set) == win32.INVALID_HANDLE) {
		return {}, false
	}
	defer win32.SetupDiDestroyDeviceInfoList(set)

	neddle := fmt.tprintf("vid_%04x&pid_%04x", mouse.vid, mouse.pid)

	device_idx: u32 = 0
	for {
		iface: win32.SP_DEVICE_INTERFACE_DATA = {
			cbSize = size_of(win32.SP_DEVICE_INTERFACE_DATA),
		}
		res := win32.SetupDiEnumDeviceInterfaces(
			set,
			nil,
			&guid,
			device_idx,
			&iface,
		)
		if !res {
			break
		}

		required_size: win32.DWORD
		res = win32.SetupDiGetDeviceInterfaceDetailW(
			set,
			&iface,
			nil,
			0,
			&required_size,
			nil,
		)
		iface_detailed_buf := make(
			[]byte,
			required_size,
			context.temp_allocator,
		)
		iface_detailed := win32.PSP_DEVICE_INTERFACE_DETAIL_DATA_W(
			&iface_detailed_buf[0],
		)
		iface_detailed.cbSize = size_of(
			win32.SP_DEVICE_INTERFACE_DETAIL_DATA_W,
		)

		res = win32.SetupDiGetDeviceInterfaceDetailW(
			set,
			&iface,
			iface_detailed,
			required_size,
			nil,
			nil,
		)
		if !res {
			device_idx += 1
			continue
		}

		wpath := win32.wstring(&iface_detailed.DevicePath[0])
		path, err := win32.wstring_to_utf8(wpath)
		if (err != nil) {
			return {}, false
		}
		if strings.contains(path, neddle) {
			dev, ok := device_open_path(wpath)
			if !ok {
				continue
			}
			pp_data: win32.PHIDP_PREPARSED_DATA
			caps: win32.HIDP_CAPS
			res := win32.HidD_GetPreparsedData(dev.handle, &pp_data)
			if (!res) {
				return {}, false
			}
			defer win32.HidD_FreePreparsedData(pp_data)
			win32.HidP_GetCaps(pp_data, &caps)
			if (caps.FeatureReportByteLength == 91) {
				return dev, true
			} else {
				device_close(&dev)
			}

		}

		device_idx += 1
	}
	return {}, false
}


@(require_results)
device_open_path :: proc(
	path: win32.wstring,
	open_rw: bool = false,
) -> (
	dev: Device,
	ok: bool,
) {
	desired_access :=
		(open_rw) ? (win32.GENERIC_WRITE | win32.GENERIC_READ) : 0
	handle := win32.CreateFileW(
		path,
		desired_access,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if handle != win32.INVALID_HANDLE {
		ok = true
	}
	return {handle}, ok
}

device_close :: proc(dev: ^Device) {
	if dev.handle != win32.INVALID_HANDLE {
		win32.CloseHandle(dev.handle)
	}
}

razer_report_set_crc :: proc(report: ^Razer_Report) {
	data := mem.ptr_to_bytes(report)
	crc: u8 = 0
	for i in 2 ..< 88 {
		crc ~= data[i]
	}
	report.crc = crc
}

@(require_results)
send_feature_report :: proc(
	dev: ^Device,
	req: ^Razer_Report,
) -> (
	rsp: Razer_Report,
	ok: bool,
) {
	req_buf, rsp_buf: [HIDBUF_SIZE]byte

	razer_report_set_crc(req)
	// println("REQUEST:", req)

	mem.copy_non_overlapping(&req_buf[1], req, REPORT_SIZE)

	res := win32.HidD_SetFeature(dev.handle, &req_buf[0], HIDBUF_SIZE)
	if (!res) {
		return rsp, false
	}

	wait_time := time.Millisecond * 31
	time.accurate_sleep(wait_time)

	for _retry := 5; _retry > 0; _retry -= 1 {
		res = win32.HidD_GetFeature(dev.handle, &rsp_buf[0], HIDBUF_SIZE)
		if res {
			rsp := cast(^Razer_Report)(&rsp_buf[1])
			if rsp.status == .COMMAND_SUCCESSFUL &&
			   rsp.transaction_id == req.transaction_id &&
			   rsp.command_id == req.command_id &&
			   rsp.command_class == req.command_class {

				return rsp^, true
			}
		}

		time.accurate_sleep(10 * time.Millisecond)
	}

	return rsp, false
}


set_dpi_stages :: proc(
	dev: ^Device,
	stages: [][2]u16,
	active_stage: u8 = 1,
) -> bool {
	assert(len(stages) > 0 && len(stages) <= RAZER_MOUSE_MAX_DPI_STAGES)
	assert(active_stage > 0 && int(active_stage) <= len(stages))

	req: Razer_Report = {
		command_class = 0x04,
		command_id    = 0x06,
		data_size     = 0x26,
	}

	a := &req.arguments

	a[0] = VARSTORE
	a[1] = active_stage
	a[2] = u8(len(stages))

	offset := 3
	for i in 0 ..< len(stages) {
		dpi := stages[i]
		// Stage number
		a[offset] = u8(i)

		// DPI X
		a[offset + 1] = u8((dpi.x >> 8) & 0xff)
		a[offset + 2] = u8(dpi.x & 0xff)
		// DPI Y
		a[offset + 3] = u8((dpi.y >> 8) & 0xff)
		a[offset + 4] = u8(dpi.y & 0xff)

		a[offset + 5] = 0
		a[offset + 6] = 0

		offset += 7
	}

	_, ok := send_feature_report(dev, &req)
	return ok
}

@(require_results)
get_dpi_stages :: proc(
	dev: ^Device,
) -> (
	_active_stage: u8,
	_stages: [dynamic][2]u16,
	_ok: bool,
) {
	req: Razer_Report = {
		command_class = 0x04,
		command_id    = 0x86,
		data_size     = 0x26,
	}
	req.arguments[0] = VARSTORE
	rsp, ok := send_feature_report(dev, &req)

	if !ok {
		_ok = false
		return
	}

	// Response format (hex):
	// 01    varstore
	// 02    active DPI stage
	// 04    number of stages = 4
	//
	// 01    first DPI stage
	// 03 20 first stage DPI X = 800
	// 03 20 first stage DPI Y = 800
	// 00 00 reserved
	//
	// 02    second DPI stage
	// 07 08 second stage DPI X = 1800
	// 07 08 second stage DPI Y = 1800
	// 00 00 reserved
	//
	// 03    third DPI stage
	// ...

	active_stage := rsp.arguments[1]
	stages_count := rsp.arguments[2]

	stages := make([dynamic][2]u16, stages_count)
	args := 4
	for i in 0 ..< stages_count {
		if args + 4 > int(rsp.data_size) {
			break
		}
		dpi := mem.slice_data_cast([]u16be, rsp.arguments[args:args + 4])
		stages[i] = {u16(dpi[0]), u16(dpi[1])}
		args += 7
	}

	return active_stage, stages, true
}

@(require_results)
get_dpi :: proc(dev: ^Device) -> (_dpi: [2]u16be, _ok: bool) {
	req: Razer_Report = {
		command_class = 0x04,
		command_id    = 0x85,
		data_size     = 0x07,
	}
	req.arguments[0] = NOTSTORE
	// req.transaction_id.id = 0x1f
	rsp, ok := send_feature_report(dev, &req)
	if ok {
		dpi := mem.slice_data_cast([]u16be, rsp.arguments[1:5])
		return {dpi[0], dpi[1]}, true
	}
	return {0, 0}, false
}

// set_dpi :: proc(dpi: int) {
// 	report: Razer_Report = {
// 		command_class = 0x04,
// 		command_id    = 0x05,
// 		data_size     = 0x07,
// 	}
// }

get_battery :: proc(dev: ^Device) -> (_battery: int, _ok: bool) {
	req: Razer_Report = {
		command_class = 0x07,
		command_id    = 0x80,
		data_size     = 0x02,
	}
	rsp, ok := send_feature_report(dev, &req)
	if ok {
		battery := int(f32(rsp.arguments[1]) / 255 * 100)
		return battery, true
	} else {
		return -1, false
	}
}

print_dpi :: proc(dev: ^Device) {
	dpi, ok := get_dpi(dev)
	if ok {
		fmt.println("DPI:", dpi)
	} else {
		fmt.eprintln("Failed to get DPI")
	}
}

print_dpi_stages :: proc(dev: ^Device) {
	active_stage, stages, ok := get_dpi_stages(dev)
	if ok {
		fmt.println("active_stage:", active_stage)
		fmt.println("stages:")
		for stage, i in stages {
			fmt.println(i + 1, stage)
		}
	} else {
		fmt.eprintln("Failed to get DPI stages")
	}
}

print_battery :: proc(dev: ^Device) {
	battery, ok := get_battery(dev)
	if ok {
		fmt.println("battery:", battery)
	} else {
		fmt.eprintln("Failed to get battery")
	}
}

print_status :: proc(dev: ^Device) {
	print_dpi(dev)
	print_battery(dev)
	print_dpi_stages(dev)
}

main :: proc() {
	dev, ok := find_mouse_device(Razer_DeathAdder_V2_X_HyperSpeed)
	if (!ok) {
		fmt.eprintln("Failed to find mouse")
		os.exit(-1)
	}
	defer device_close(&dev)

	argc := len(os.args)
	if argc >= 2 {
		cmd := os.args[1]
		switch cmd {
		case "status":
			print_status(&dev)
		case "setdpi":
			if argc < 3 {
				fmt.eprintln("Not enough args, dpi is not provided")
			} else {
				dpi: uint
				dpi, ok = strconv.parse_uint(os.args[2])
				assert(ok && dpi <= auto_cast max(u16))
				stages: [][2]u16 = {{u16(dpi), u16(dpi)}}
				set_dpi_stages(&dev, stages, 1)
			}
		case "reset":
			stages: [][2]u16 = {
				{800, 800},
				{1600, 1600},
				{3200, 3200},
				{4800, 4800},
				{6400, 6400},
			}
			set_dpi_stages(&dev, stages, 1)
		case "help":
			fmt.eprintln("Avaliable commands: status, setdpi, reset, help")
		case:
			fmt.eprintln("Unknown command:", cmd)
		}
	} else {
		print_status(&dev)
	}
}
