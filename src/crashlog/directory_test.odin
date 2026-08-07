#+vet explicit-allocators
package crashlog

import "core:os"
import "core:strings"
import "core:testing"

@(test)
directory_under_joins_a_transcibr_subdirectory :: proc(t: ^testing.T) {
	dir := directory_under("C:\\Users\\alice\\AppData\\Local", context.allocator)
	defer delete(dir, context.allocator)

	testing.expect_value(t, dir, "C:\\Users\\alice\\AppData\\Local\\transcibr")
}

@(test)
default_directory_creates_a_real_directory_under_local_appdata :: proc(t: ^testing.T) {
	dir, ok := default_directory(context.allocator)
	defer delete(dir, context.allocator)

	testing.expect(t, ok, "%LOCALAPPDATA% is unset or refused on this machine")
	testing.expect(
		t,
		strings.has_suffix(dir, "\\transcibr"),
		"the resolved directory does not carry this program's name",
	)

	info, err := os.stat(dir, context.allocator)
	defer os.file_info_delete(info, context.allocator)
	testing.expect(t, err == nil, "default_directory reported success but made nothing")
	testing.expect(
		t,
		info.type == .Directory,
		"default_directory made a file where a directory belongs",
	)
}
