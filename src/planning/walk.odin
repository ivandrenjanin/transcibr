package planning

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
import "core:time"
import "transcibr:artifact"

// Discovery: the shell half of this package. Walking a tree is I/O and cannot be
// anything else (ADR-0009), so what is decided here is kept to what a case can
// still reach -- and the decisions themselves live beside it in plan.odin.

// Containers ffmpeg reads and a Recording plausibly arrives in. A walk that
// probed every file to find out would spend an ffprobe per README in the tree,
// which is the GPU-free cost this ticket exists to keep down.
@(private, rodata)
RECORDING_SUFFIXES := [?]string {
	".mp4",
	".m4v",
	".mkv",
	".webm",
	".mov",
	".avi",
	".wmv",
	".flv",
	".mpg",
	".mpeg",
	".ts",
	".m2ts",
	".3gp",
	".mp3",
	".m4a",
	".aac",
	".wav",
	".flac",
	".ogg",
	".oga",
	".opus",
	".wma",
	".aiff",
	".aif",
}

// `artifact.extension_of` is asked rather than the path searched, so a walk and
// the naming that follows it cut a path in exactly one place.
is_a_recording :: proc(path: string) -> bool {
	extension := artifact.extension_of(path)
	if len(extension) == 0 {
		return false
	}
	for known in RECORDING_SUFFIXES {
		if strings.equal_fold(extension, known) {
			return true
		}
	}
	return false
}

// Deep enough for any archive somebody points at and far short of anything that
// costs a thread its stack. The walk keeps its own frontier rather than
// recursing, so this bounds a pathological tree and not this program's stack.
MAX_WALK_DEPTH :: 64

#assert(MAX_WALK_DEPTH > 0)

// What a walk could not do, against the directory it could not do it to. Every
// one of these is an operating error and none of them is silence: a short file
// list is the one discovery failure a user cannot detect (ADR-0009).
Note :: enum u8 {
	Root_Unreadable = 0,
	Directory_Unreadable,
	Reparse_Point_Not_Followed,
	Too_Deep,
}

Walk_Note :: struct {
	note: Note,
	// Owned by the Inventory and freed with destroy_inventory.
	path: string,
}

// Handed to `on_progress` as the walk goes. `at` is borrowed for the length of
// the call and is not alive after it returns.
Progress :: struct {
	directories: int,
	recordings:  int,
	at:          string,
}

// How a caller off the interface thread drives discovery. `cancelled` is read
// atomically on the walking thread and written by whoever wants it to stop, so
// the window issue #16 builds needs no more of a seam than a bool it owns.
// Nothing here starts a thread; what runs the walk is the caller's to decide.
Walk :: struct {
	cancelled:             ^bool,
	on_progress:           proc(progress: Progress, user: rawptr),
	user:                  rawptr,
	// Off by default, and the whole of what turns it on. Why a reparse point is
	// not followed at all rather than followed once: ADR-0026.
	follow_reparse_points: bool,
}

// Every string inside is owned; free the whole with destroy_inventory and the
// allocator that was handed in.
Inventory :: struct {
	found:     []Found,
	notes:     []Walk_Note,
	cancelled: bool,
}

// Whether the inventory is the whole tree. A reparse point not followed is what
// the caller ASKED for and leaves it whole; everything else means Recordings
// exist that nothing looked at, and a caller that reported success over that
// would be the silently short file list ADR-0009 names.
left_unlooked_at :: proc(inventory: Inventory) -> (short: Note, yes: bool) {
	if inventory.cancelled {
		return .Root_Unreadable, true
	}
	for note in inventory.notes {
		if note.note == .Reparse_Point_Not_Followed {
			continue
		}
		return note.note, true
	}
	return .Root_Unreadable, false
}

// A cancelled walk answers with what it had got to, not with nothing: the notes
// and the Recordings already found are still true.
discover :: proc(roots: []string, w: Walk, allocator: mem.Allocator) -> (inventory: Inventory) {
	assert(
		allocator.procedure != nil,
		"the inventory outlives this procedure and needs an allocator",
	)
	defer assert(
		inventory.cancelled || len(roots) > 0 || len(inventory.found) == 0,
		"a walk over no roots at all found something",
	)

	state := Walking {
		w         = w,
		found     = make([dynamic]Found, 0, 64, allocator),
		notes     = make([dynamic]Walk_Note, 0, 8, allocator),
		allocator = allocator,
	}
	for root in roots {
		walk_root(&state, root)
	}

	shrink(&state.found)
	shrink(&state.notes)
	return Inventory{found = state.found[:], notes = state.notes[:], cancelled = state.cancelled}
}

destroy_inventory :: proc(inventory: Inventory, allocator: mem.Allocator) {
	for entry in inventory.found {
		delete(entry.source, allocator)
		destroy_recorded(entry, allocator)
	}
	for note in inventory.notes {
		delete(note.path, allocator)
	}
	delete(inventory.found, allocator)
	delete(inventory.notes, allocator)
}

@(private)
destroy_recorded :: proc(entry: Found, allocator: mem.Allocator) {
	recorded, known := entry.recorded.?
	if !known {
		return
	}
	artifact.destroy_sidecar(recorded, allocator)
}

@(private)
Walking :: struct {
	w:           Walk,
	found:       [dynamic]Found,
	notes:       [dynamic]Walk_Note,
	allocator:   mem.Allocator,
	directories: int,
	cancelled:   bool,
}

// A directory still to be enumerated. The path is owned by the frontier and
// freed as it comes off.
@(private)
Pending :: struct {
	path:  string,
	depth: int,
}

// A root that will not open is reported against ITSELF and not as an empty
// result: a Batch pointed at a share that has stopped answering must say so.
@(private)
walk_root :: proc(state: ^Walking, root: string) {
	assert(state != nil, "there is no walk here to run")

	if len(root) == 0 {
		note(state, .Root_Unreadable, root)
		return
	}
	if !enumerable(state.w, root, state.allocator) {
		note(state, .Root_Unreadable, root)
		return
	}

	frontier := make([dynamic]Pending, 0, 32, state.allocator)
	defer abandon(frontier, state.allocator)
	append(&frontier, Pending{path = strings.clone(root, state.allocator), depth = 0})

	for len(frontier) > 0 {
		pending := pop(&frontier)
		defer delete(pending.path, state.allocator)
		if stopped(state) {
			return
		}
		walk_one(state, pending, &frontier)
	}
}

// A cancelled walk leaves directories it never reached still on the frontier,
// and each of them owns its path.
@(private)
abandon :: proc(frontier: [dynamic]Pending, allocator: mem.Allocator) {
	assert(allocator.procedure != nil, "a frontier is freed with the allocator that built it")

	for pending in frontier {
		delete(pending.path, allocator)
	}
	delete(frontier)
}

@(private)
walk_one :: proc(state: ^Walking, pending: Pending, frontier: ^[dynamic]Pending) {
	assert(state != nil, "there is no walk here to run")
	assert(frontier != nil, "there is nowhere here to put a sub-directory")

	listing, unreadable := os.read_all_directory_by_path(pending.path, state.allocator)
	if unreadable != nil {
		note(state, .Directory_Unreadable, pending.path)
		return
	}
	defer os.file_info_slice_delete(listing, state.allocator)

	state.directories += 1
	writable := directory_writable(pending.path, state.allocator)
	report(state, pending.path)

	for info in listing {
		if stopped(state) {
			return
		}
		took(state, info, pending, frontier, writable)
	}
}

@(private)
took :: proc(
	state: ^Walking,
	info: os.File_Info,
	pending: Pending,
	frontier: ^[dynamic]Pending,
	writable: bool,
) {
	assert(state != nil, "there is no walk here to run")
	assert(len(info.fullpath) > 0, "a directory entry with no path at all")

	if !state.w.follow_reparse_points && is_a_reparse_point(info.fullpath, state.allocator) {
		note(state, .Reparse_Point_Not_Followed, info.fullpath)
		return
	}
	if info.type == .Directory {
		descend(state, info.fullpath, pending.depth, frontier)
		return
	}
	if info.type != .Regular && info.type != .Undetermined {
		return
	}
	if !is_a_recording(info.fullpath) {
		return
	}
	append(&state.found, looked_at(state, info, writable))
}

@(private)
descend :: proc(state: ^Walking, path: string, depth: int, frontier: ^[dynamic]Pending) {
	assert(state != nil, "there is no walk here to run")
	assert(depth >= 0, "a directory at a negative depth")

	if depth + 1 > MAX_WALK_DEPTH {
		note(state, .Too_Deep, path)
		return
	}
	append(frontier, Pending{path = strings.clone(path, state.allocator), depth = depth + 1})
}

// Everything a decision will rest on, read here so that nothing in plan.odin
// has to. The Sidecar is read WHOLE or not at all; `artifact.read_sidecar`
// refuses a partial record rather than filling the gaps with zeroes.
@(private)
looked_at :: proc(state: ^Walking, info: os.File_Info, writable: bool) -> (found: Found) {
	assert(state != nil, "there is no walk here to run")
	assert(len(info.fullpath) > 0, "a Recording with no path at all")

	found = Found {
		source             = strings.clone(info.fullpath, state.allocator),
		bytes              = info.size,
		modified_ns        = time.time_to_unix_nano(info.modification_time),
		directory_writable = writable,
	}

	names, namable := artifact.names_of(found.source, state.allocator)
	defer artifact.destroy_names(names, state.allocator)
	if !namable {
		return found
	}

	found.transcript = transcript_state(names[.Transcript])
	found.engine_output = os.is_file(names[.Engine_Output])
	found.recorded = sidecar_at(names[.Sidecar], state.allocator)
	return found
}

// An unreadable Sidecar and an absent one are one answer, which is ADR-0003's
// disposition for unknown provenance: re-do it.
@(private)
sidecar_at :: proc(path: string, allocator: mem.Allocator) -> Maybe(artifact.Sidecar) {
	assert(len(path) > 0, "there is nowhere here to read a Sidecar from")
	assert(allocator.procedure != nil, "a Sidecar outlives this procedure and needs an allocator")

	text, unreadable := os.read_entire_file_from_path(path, allocator)
	if unreadable != nil {
		return nil
	}
	defer delete(text, allocator)

	recorded, readable := artifact.read_sidecar(string(text), allocator)
	if !readable {
		return nil
	}
	return recorded
}

// The head and never the whole file: a Transcript is megabytes, and what is
// being asked is who wrote it.
@(private)
transcript_state :: proc(path: string) -> Transcript_State {
	assert(len(path) > 0, "there is nowhere here to look for a Transcript")

	handle, unopenable := os.open(path)
	if unopenable != nil {
		return .Absent
	}
	defer os.close(handle)

	head: [TRANSCRIPT_HEAD_BYTES]u8 = ---
	read, unreadable := os.read_at(handle, head[:], 0)
	if unreadable != nil && read == 0 {
		return .Foreign
	}
	assert(read <= len(head), "more of a Transcript came back than there was room for it")

	if written_by_transcibr(string(head[:read])) {
		return .Transcibrs
	}
	return .Foreign
}

@(private)
note :: proc(state: ^Walking, what: Note, path: string) {
	assert(state != nil, "there is no walk here to report against")

	append(&state.notes, Walk_Note{note = what, path = strings.clone(path, state.allocator)})
}

@(private)
report :: proc(state: ^Walking, at: string) {
	assert(state != nil, "there is no walk here to report on")

	if state.w.on_progress == nil {
		return
	}
	state.w.on_progress(
		Progress{directories = state.directories, recordings = len(state.found), at = at},
		state.w.user,
	)
}

// Read atomically because the flag is written on another thread by design, and
// a plain read of a value another thread stores is a race whatever the width.
@(private)
stopped :: proc(state: ^Walking) -> bool {
	assert(state != nil, "there is no walk here to stop")

	if state.w.cancelled == nil {
		return false
	}
	if sync.atomic_load(state.w.cancelled) {
		state.cancelled = true
	}
	return state.cancelled
}

// One probe per DIRECTORY and never per Recording: the answer is a fact about
// the directory, and a Batch of hundreds beside each other would otherwise open
// and delete a file hundreds of times to learn it once.
@(private)
directory_writable :: proc(directory: string, allocator: mem.Allocator) -> bool {
	assert(len(directory) > 0, "there is no directory here to write into")
	assert(allocator.procedure != nil, "a probe name needs an allocator to be built in")

	probe := fmt.aprintf(
		"%s\\.transcibr-writable.%d",
		directory,
		os.get_pid(),
		allocator = allocator,
	)
	defer delete(probe, allocator)

	handle, unopenable := os.open(probe, {.Write, .Create, .Trunc})
	if unopenable != nil {
		return false
	}
	os.close(handle)
	os.remove(probe)
	return true
}

@(private)
enumerable :: proc(w: Walk, path: string, allocator: mem.Allocator) -> bool {
	assert(len(path) > 0, "there is nothing here to enumerate")
	assert(allocator.procedure != nil, "asking about a path needs an allocator to widen it")

	if !w.follow_reparse_points && is_a_reparse_point(path, allocator) {
		return false
	}
	return os.is_dir(path)
}

// `core:os` cannot answer this: `_file_type_mode_from_file_attributes` calls a
// directory carrying ANY reparse tag but SYMLINK or MOUNT_POINT a plain
// `.Directory`, so a walk that trusted `File_Type` would follow a cloud-files
// placeholder or an AppExecLink straight through. Measured, and why the attribute
// is read directly: ADR-0026.
@(private)
is_a_reparse_point :: proc(path: string, allocator: mem.Allocator) -> bool {
	assert(len(path) > 0, "there is nothing here to ask about")
	assert(allocator.procedure != nil, "a path crossing into Win32 needs an allocator to widen it")

	wide := win32.utf8_to_utf16(path, allocator)
	defer delete(wide, allocator)
	if wide == nil {
		return true
	}

	attributes := win32.GetFileAttributesW(win32.wstring(raw_data(wide)))
	if attributes == win32.INVALID_FILE_ATTRIBUTES {
		return false
	}
	return attributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0
}
