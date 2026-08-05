#+vet explicit-allocators
package child

import win32 "core:sys/windows"

// The parts of Win32 that `core:sys/windows` does not bind, declared by hand.
// Every structure here is a byte image Win32 reads a declared size out of, which
// is what the size assertions beside them hold.

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

	// Cancels a synchronous I/O call blocked on the named thread from outside
	// it -- the one Win32 primitive that reaches into a `ReadFile` a bounded
	// read is stuck in and makes it return rather than block forever. See
	// `await_or_abandon` in read.odin for the measurement that proves this
	// actually reclaims the thread.
	CancelSynchronousIo :: proc(hThread: win32.HANDLE) -> win32.BOOL ---
}

// Opaque: Windows says how many bytes it needs and no field is ever read.
LPPROC_THREAD_ATTRIBUTE_LIST :: rawptr

// The header BUILDS this rather than stating it: handle-list attribute 2 or'd
// with PROC_THREAD_ATTRIBUTE_INPUT, which is 0x00020000. A plain 2 is a different
// attribute and is refused.
PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: 0x00020002

// The `cb` inside must be `size_of` THIS and the creation flags must carry
// EXTENDED_STARTUPINFO_PRESENT, or the extra pointer is never looked at and the
// handle list silently does nothing.
STARTUPINFOEXW :: struct {
	StartupInfo:     win32.STARTUPINFOW,
	lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
}

// No padding of its own before the pointer is what makes `&x.StartupInfo` a
// pointer to the whole record as far as Windows is concerned.
#assert(size_of(STARTUPINFOEXW) == size_of(win32.STARTUPINFOW) + size_of(rawptr))

JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION :: 1
JOB_OBJECT_EXTENDED_LIMIT_INFORMATION :: 9

// When the LAST handle to the job closes, every process still in it is
// terminated. Process exit closes the handles a process held, so a parent that
// crashes or is killed still takes its children with it (ADR-0004).
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x00002000

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

// Declared whole to read one field, `ActiveProcesses`: a job object has no wait
// primitive for emptying -- it signals only when its end-of-job time limit is
// exceeded -- so the counter is the only way to ask.
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

// Declared whole though only `BasicLimitInformation.LimitFlags` is ever written:
// `SetInformationJobObject` is handed `size_of` this, and a struct short by the
// trailing counters is a length Windows refuses.
JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
	BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
	IoInfo:                IO_COUNTERS,
	ProcessMemoryLimit:    win32.SIZE_T,
	JobMemoryLimit:        win32.SIZE_T,
	PeakProcessMemoryUsed: win32.SIZE_T,
	PeakJobMemoryUsed:     win32.SIZE_T,
}

#assert(size_of(JOBOBJECT_EXTENDED_LIMIT_INFORMATION) == 144)
