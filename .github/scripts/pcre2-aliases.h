/* Included at the end of ext/pcre/php_pcre.c by build-interpreter.sh, followed
 * by one PHP_DEBUGGER_PCRE2_ALIAS(standard, bundled) line per PCRE2 function.
 *
 * PHP's bundled PCRE2 functions are called php_pcre2_* (main/php_compat.h).
 * Extensions built against a PHP that uses the system PCRE2 (the distributions'
 * and Homebrew's) call the standard pcre2_*_8 names instead. Each alias is an
 * exported stub under the standard name that tail-jumps to the bundled
 * function, so there is still one PCRE2 and the arguments pass through
 * untouched, whatever the function's signature. */
#if defined(__APPLE__) && defined(__aarch64__)
#  define PHP_DEBUGGER_PCRE2_ALIAS(standard, bundled) \
	__asm__(".text\n.globl _" standard "\n.p2align 2\n_" standard ":\n\tb _" bundled "\n");
#elif defined(__aarch64__)
#  define PHP_DEBUGGER_PCRE2_ALIAS(standard, bundled) \
	__asm__(".text\n.globl " standard "\n.type " standard ", %function\n.p2align 2\n" standard ":\n\tb " bundled "\n");
#elif defined(__x86_64__) && !defined(__APPLE__)
#  define PHP_DEBUGGER_PCRE2_ALIAS(standard, bundled) \
	__asm__(".text\n.globl " standard "\n.type " standard ", @function\n" standard ":\n\tjmp " bundled "\n");
#else
#  error "no PCRE2 alias stub for this platform"
#endif
