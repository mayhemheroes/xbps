/*
 * xbps_plist_fuzzer.c — fuzz xbps' proplib (portableproplib) plist PARSER.
 *
 * xbps stores ALL package metadata (the per-package "props.plist"/"files.plist",
 * the repository index "<arch>-repodata", pkgdb, etc.) as Apple-style XML
 * property lists, parsed by the bundled portableproplib. The single
 * attacker-reachable entry point that turns untrusted bytes into an object graph
 * is xbps_dictionary_internalize(const char *) — it parses an in-memory,
 * NUL-terminated XML plist string into a dictionary. A repository / package can
 * feed arbitrary bytes here, so this is the parse surface we fuzz.
 *
 * The harness:
 *   1. copies the fuzz input into a NUL-terminated heap buffer (the API takes a C
 *      string; embedded NULs simply truncate, matching real callers),
 *   2. internalizes it into a dictionary,
 *   3. on success, round-trips it back out via xbps_dictionary_externalize()
 *      (exercises the serializer over the just-parsed graph) and releases both.
 *
 * Built against the project's own libxbps.a (its ./configure + make), with the
 * library itself compiled under $SANITIZER_FLAGS so the parser code — not just
 * the harness — is instrumented.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <xbps.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	/* xbps_dictionary_internalize() expects a NUL-terminated C string. */
	char *xml = malloc(size + 1);
	if (xml == NULL)
		return 0;
	memcpy(xml, data, size);
	xml[size] = '\0';

	xbps_dictionary_t dict = xbps_dictionary_internalize(xml);
	free(xml);

	if (xbps_object_type(dict) == XBPS_TYPE_DICTIONARY) {
		/* Round-trip: serialize the parsed graph back to XML. */
		char *out = xbps_dictionary_externalize(dict);
		free(out);
	}
	if (dict != NULL)
		xbps_object_release(dict);

	return 0;
}
