/*
 * Zig's Windows/MSVC libc exposes the underscored UCRT entry points, while
 * parts of metacodes-core intentionally retain POSIX spellings. Keep those
 * aliases private to the static archive instead of forcing every consumer to
 * locate a Visual C++ oldnames library.
 */
#include <limits.h>
#include <stddef.h>

extern int _unlink(const char *path);
extern int _mkdir(const char *path);
extern int _rmdir(const char *path);
extern int _access(const char *path, int mode);
extern int _chdir(const char *path);
extern char *_getcwd(char *buffer, int max_length);

int unlink(const char *path) { return _unlink(path); }

int mkdir(const char *path, unsigned int mode) {
    (void)mode;
    return _mkdir(path);
}

int rmdir(const char *path) { return _rmdir(path); }

int access(const char *path, int mode) {
    /* MSVCRT has no execute bit; X_OK means that the launchable path exists. */
    return _access(path, mode == 1 ? 0 : mode);
}

int chdir(const char *path) { return _chdir(path); }

char *getcwd(char *buffer, size_t max_length) {
    if (max_length > INT_MAX) return NULL;
    return _getcwd(buffer, (int)max_length);
}
