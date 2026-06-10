/*
 * xbps/mayhem/test_oracle.c — a small self-contained GOLDEN oracle over the exact parse path the
 * fuzzer drives (xbps_dictionary_internalize / xbps_dictionary_externalize from libxbps' bundled
 * portableproplib). It is built and run by mayhem/test.sh with NORMAL (non-sanitizer) flags.
 *
 * Why not kyua/ATF? xbps' upstream suite is kyua-based and needs the full installed toolchain +
 * helper utilities + an ATF runtime. This oracle instead asserts CONCRETE behaviour of the fuzzed
 * API, so it is a real PATCH-grade oracle: a no-op / "return success" patch to the parser cannot
 * pass, because we check parsed values, container shapes, round-trip stability, and rejection of
 * malformed input — byte/semantics level, not "did it not crash".
 *
 * Each check returns 1 on pass, 0 on fail; main prints "PASS <n>"/"FAIL <n>" per check and exits
 * non-zero if any failed. test.sh turns this into CTRF.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <xbps.h>

static int npass, nfail;
#define CHECK(name, cond) do { \
	if (cond) { printf("PASS %s\n", (name)); npass++; } \
	else { printf("FAIL %s\n", (name)); nfail++; } \
} while (0)

static const char *GOOD =
	"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
	"<!DOCTYPE plist PUBLIC \"-//Apple Computer//DTD PLIST 1.0//EN\" "
	"\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
	"<plist version=\"1.0\">\n"
	"<dict>\n"
	"  <key>pkgver</key>\n"
	"  <string>hello-2.10_1</string>\n"
	"  <key>installed_size</key>\n"
	"  <integer>123456</integer>\n"
	"  <key>automatic-install</key>\n"
	"  <true/>\n"
	"  <key>run_depends</key>\n"
	"  <array>\n"
	"    <string>libc-2.36_1</string>\n"
	"  </array>\n"
	"</dict>\n"
	"</plist>\n";

int main(void)
{
	xbps_dictionary_t d = xbps_dictionary_internalize(GOOD);

	/* 1) a well-formed plist must internalize to a dictionary */
	CHECK("internalize_good_is_dict",
	      xbps_object_type(d) == XBPS_TYPE_DICTIONARY);

	if (d != NULL && xbps_object_type(d) == XBPS_TYPE_DICTIONARY) {
		/* 2) top-level key count is exactly 4 */
		CHECK("dict_count_4", xbps_dictionary_count(d) == 4);

		/* 3) string value parsed verbatim */
		const char *pkgver = NULL;
		xbps_dictionary_get_cstring_nocopy(d, "pkgver", &pkgver);
		CHECK("pkgver_value",
		      pkgver != NULL && strcmp(pkgver, "hello-2.10_1") == 0);

		/* 4) integer value parsed correctly */
		uint64_t isize = 0;
		bool got = xbps_dictionary_get_uint64(d, "installed_size", &isize);
		CHECK("integer_value", got && isize == 123456ULL);

		/* 5) boolean <true/> parsed correctly */
		bool autoinst = false;
		got = xbps_dictionary_get_bool(d, "automatic-install", &autoinst);
		CHECK("bool_value", got && autoinst);

		/* 6) nested array is an array with one element */
		xbps_array_t arr = xbps_dictionary_get(d, "run_depends");
		CHECK("array_type", xbps_object_type(arr) == XBPS_TYPE_ARRAY);
		CHECK("array_count_1", xbps_array_count(arr) == 1);

		/* 7) externalize -> re-internalize round-trip is stable in shape */
		char *xml = xbps_dictionary_externalize(d);
		CHECK("externalize_nonnull", xml != NULL);
		if (xml != NULL) {
			xbps_dictionary_t d2 = xbps_dictionary_internalize(xml);
			CHECK("roundtrip_is_dict",
			      xbps_object_type(d2) == XBPS_TYPE_DICTIONARY);
			CHECK("roundtrip_count_match",
			      d2 != NULL && xbps_dictionary_count(d2) == 4);
			if (d2 != NULL)
				xbps_object_release(d2);
			free(xml);
		}
		xbps_object_release(d);
	}

	/* 8) malformed input (unterminated dict) must be REJECTED (NULL), not silently accepted */
	xbps_dictionary_t bad = xbps_dictionary_internalize(
	    "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>x</key>");
	CHECK("reject_truncated", bad == NULL);
	if (bad != NULL)
		xbps_object_release(bad);

	/* 9) empty / non-plist garbage must be rejected */
	xbps_dictionary_t junk = xbps_dictionary_internalize("not xml at all");
	CHECK("reject_garbage", junk == NULL);
	if (junk != NULL)
		xbps_object_release(junk);

	printf("\nsummary: %d passed, %d failed\n", npass, nfail);
	return nfail == 0 ? 0 : 1;
}
