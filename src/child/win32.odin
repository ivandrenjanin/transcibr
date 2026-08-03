package child

import win32 "core:sys/windows"

// This file is the part of Win32 that `core:sys/windows` does not bind, declared
// by hand. ADR-0004 predicted four of these by name -- `CreateJobObjectW`,
// `AssignProcessToJobObject`, `SetInformationJobObject` and
// `SetThreadExecutionState` -- and the count is a floor rather than the list: the
// rest below were found missing the same way, by asking the pinned compiler's own
// `core` sources rather than a tutorial (CLAUDE.md's Odin notes).
//
// EVERYTHING HERE IS A BYTE IMAGE OR AN ENTRY POINT, so nothing in it may be
// paraphrased. The structures carry `#assert(size_of(...))` next to them (rule
// A5) because Win32 reads a declared size out of the struct and refuses, or
// worse silently misreads, when the field layout drifts -- and a layout mistake
// in a `SIZE_T` that a 32-bit reading would have got wrong is invisible in source
// and immediate in behaviour.

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	CreateJobObjectW :: proc(lpJobAttributes: win32.LPSECURITY_ATTRIBUTES, lpName: win32.LPCWSTR) -> win32.HANDLE ---
	AssignProcessToJobObject :: proc(hJob: win32.HANDLE, hProcess: win32.HANDLE) -> win32.BOOL ---
	SetInformationJobObject :: proc(hJob: win32.HANDLE, JobObjectInformationClass: i32, lpJobObjectInformation: win32.LPVOID, cbJobObjectInformationLength: win32.DWORD) -> win32.BOOL ---
	QueryInformationJobObject :: proc(hJob: win32.HANDLE, JobObjectInformationClass: i32, lpJobObjectInformation: win32.LPVOID, cbJobObjectInformationLength: win32.DWORD, lpReturnLength: ^win32.DWORD) -> win32.BOOL ---
	TerminateJobObject :: proc(hJob: win32.HANDLE, uExitCode: win32.UINT) -> win32.BOOL ---
	GetTickCount64 :: proc() -> win32.ULONGLONG ---
	InitializeProcThreadAttributeList :: proc(lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST, dwAttributeCount: win32.DWORD, dwFlags: win32.DWORD, lpSize: ^win32.SIZE_T) -> win32.BOOL ---
	UpdateProcThreadAttribute :: proc(lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST, dwFlags: win32.DWORD, Attribute: win32.DWORD_PTR, lpValue: win32.PVOID, cbSize: win32.SIZE_T, lpPreviousValue: win32.PVOID, lpReturnSize: ^win32.SIZE_T) -> win32.BOOL ---
	DeleteProcThreadAttributeList :: proc(lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST) ---
}

// The attribute list is OPAQUE: Windows says how many bytes it needs and this
// package supplies them, never reading a field. Declaring it as a pointer to
// nothing is the honest shape and is what the header does.
LPPROC_THREAD_ATTRIBUTE_LIST :: rawptr

// `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, which the header BUILDS rather than states:
// `ProcThreadAttributeValue(ProcThreadAttributeHandleList=2, thread=FALSE,
// input=TRUE, additive=FALSE)` is `2 | PROC_THREAD_ATTRIBUTE_INPUT`, and
// PROC_THREAD_ATTRIBUTE_INPUT is 0x00020000. A plain 2 -- which is what the
// enumeration member alone would suggest -- is not this attribute and is refused.
PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: 0x00020002

// STARTUPINFOW with the attribute list bolted on the end, which is the only way
// to hand `CreateProcessW` one. The `cb` inside must be `size_of` THIS, and the
// creation flags must carry EXTENDED_STARTUPINFO_PRESENT, or the extra pointer is
// never looked at and the handle list silently does nothing.
STARTUPINFOEXW :: struct {
	StartupInfo:     win32.STARTUPINFOW,
	lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
}

// Stated as a relationship rather than as a number, because the number is not the
// claim: what matters is that the pointer sits immediately after the embedded
// structure with no padding of its own, which is what makes `&x.StartupInfo` a
// pointer to the whole record as far as Windows is concerned.
#assert(size_of(STARTUPINFOEXW) == size_of(win32.STARTUPINFOW) + size_of(rawptr))

// The two members of the JOBOBJECTINFOCLASS enumeration this package names:
// `JobObjectBasicAccountingInformation` and `JobObjectExtendedLimitInformation`.
JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION :: 1
JOB_OBJECT_EXTENDED_LIMIT_INFORMATION :: 9

// The limit that makes a job object a kill switch: when the LAST handle to the
// job closes, every process still in it is terminated. Process exit closes the
// handles a process holds, so a parent that crashes, is killed, or exits without
// running any cleanup at all still takes its children with it -- which is the
// only mechanism that survives the case ADR-0004 is about, an Engine holding
// three gigabytes of video memory after transcibr is gone.
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x00002000

// x64 field-by-field, and the padding is part of the claim: `LimitFlags` is four
// bytes followed by four bytes of padding before an eight-byte `SIZE_T`, and so
// is `ActiveProcessLimit`. Sixty-four bytes is what says both paddings are there.
JOBOBJECT_BASIC_LIMIT_INFORMATION :: struct {
	PerProcessUserTimeLimit: win32.LARGE_INTEGER,
	PerJobUserTimeLimit:     win32.LARGE_INTEGER,
	LimitFlags:              win32.DWORD,
	MinimumWorkingSetSize:   win32.SIZE_T,
	MaximumWorkingSetSize:   win32.SIZE_T,
	ActiveProcessLimit:      win32.DWORD,
	Affinity:                win32.ULONG_PTR,
	PriorityClass:           win32.DWORD,
	SchedulingClass:         win32.DWORD,
}

#assert(size_of(JOBOBJECT_BASIC_LIMIT_INFORMATION) == 64)

// Read for ONE field: `ActiveProcesses`, which is how "everything in this job
// object is gone" is asked. There is no wait primitive for it -- a job object
// signals when its end-of-job time limit is exceeded and never when it empties --
// so the whole record is declared to ask a counter.
JOBOBJECT_BASIC_ACCOUNTING_INFORMATION :: struct {
	TotalUserTime:             win32.LARGE_INTEGER,
	TotalKernelTime:           win32.LARGE_INTEGER,
	ThisPeriodTotalUserTime:   win32.LARGE_INTEGER,
	ThisPeriodTotalKernelTime: win32.LARGE_INTEGER,
	TotalPageFaultCount:       win32.DWORD,
	TotalProcesses:            win32.DWORD,
	ActiveProcesses:           win32.DWORD,
	TotalTerminatedProcesses:  win32.DWORD,
}

#assert(size_of(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION) == 48)

IO_COUNTERS :: struct {
	ReadOperationCount:  win32.ULONGLONG,
	WriteOperationCount: win32.ULONGLONG,
	OtherOperationCount: win32.ULONGLONG,
	ReadTransferCount:   win32.ULONGLONG,
	WriteTransferCount:  win32.ULONGLONG,
	OtherTransferCount:  win32.ULONGLONG,
}

#assert(size_of(IO_COUNTERS) == 48)

// Declared whole even though only `BasicLimitInformation.LimitFlags` is ever
// written. `SetInformationJobObject` is handed `size_of` this, and a struct
// short by the trailing counters is a length Windows refuses -- so the unused
// tail is not decoration, it is the reason the call is accepted.
JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
	BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
	IoInfo:                IO_COUNTERS,
	ProcessMemoryLimit:    win32.SIZE_T,
	JobMemoryLimit:        win32.SIZE_T,
	PeakProcessMemoryUsed: win32.SIZE_T,
	PeakJobMemoryUsed:     win32.SIZE_T,
}

#assert(size_of(JOBOBJECT_EXTENDED_LIMIT_INFORMATION) == 144)
