#+vet explicit-allocators
package doctor

import "core:strings"
import "core:testing"
import "transcibr:artifact"

@(test)
the_rendered_engine_identity_names_the_digest_it_was_given :: proc(t: ^testing.T) {
	digest := artifact.Digest(strings.repeat("a", artifact.DIGEST_CHARS, context.allocator))
	defer delete(string(digest), context.allocator)

	line := render_engine_identity(digest, context.allocator)
	defer delete(line, context.allocator)

	testing.expect(
		t,
		strings.contains(line, string(digest)),
		"the rendered line does not name the digest it was given",
	)
}

// A different digest renders a different line -- the whole point of
// reporting the digest at all (ADR-0037: content, not the path, is what
// identity means here).
@(test)
two_different_digests_render_two_different_lines :: proc(t: ^testing.T) {
	a := artifact.Digest(strings.repeat("a", artifact.DIGEST_CHARS, context.allocator))
	defer delete(string(a), context.allocator)
	b := artifact.Digest(strings.repeat("b", artifact.DIGEST_CHARS, context.allocator))
	defer delete(string(b), context.allocator)

	line_a := render_engine_identity(a, context.allocator)
	defer delete(line_a, context.allocator)
	line_b := render_engine_identity(b, context.allocator)
	defer delete(line_b, context.allocator)

	testing.expect(
		t,
		line_a != line_b,
		"two different Engine digests rendered as the identical line",
	)
}
