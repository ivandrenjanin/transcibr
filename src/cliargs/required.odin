#+vet explicit-allocators
// The required-field sweep: the byte-identical shape measured at four
// src/cli sites (ADR-0038) -- a `for missing in ([?][2]string{...})` loop
// refusing the first empty required field, generalized to any command's own
// list of {value, name} pairs.
package cliargs

Required_Field :: struct {
	value: string,
	name:  string,
}

REQUIRED_FIELD_EMPTY_COMPLAINT :: "%s names nothing."

@(require_results)
required_fields_present :: proc(fields: []Required_Field) -> (ok: bool, refusal: Refusal) {
	assert(len(fields) > 0, "a sweep with nothing to check is not a sweep")
	defer if ok {
		for field in fields {
			assert(len(field.value) > 0, "a sweep passed with an empty field still in it")
		}
	}

	for field in fields {
		if len(field.value) == 0 {
			return false, make_refusal(REQUIRED_FIELD_EMPTY_COMPLAINT, Refusal_Arg(field.name))
		}
	}
	return true, {}
}
