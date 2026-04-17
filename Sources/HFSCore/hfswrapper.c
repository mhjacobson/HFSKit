// hfswrapper.c
// HFSKit - A Swift wrapper of hfsutils for editing HFS disk images
// Copyright (C) 2026 David Kopec
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.


#include "hfswrapper.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

/* libhfs header from hfsutils (must be in your include path). */
#include "libhfs.h"
#include "low.h"
#include "volume.h"
#include "copyin.h"
#include "hcopy.h"
#include "binhex.h"

int hfsck(hfsvol *, int);
#define HFSCK_REPAIR  0x0001
#define HFSCK_VERBOSE 0x0100
#define HFSCK_YES     0x0200

/* ---- Internal helpers -------------------------------------------------- */

int hfs_debug_logging_enabled = 1;

static const char *
normalize_error_detail(const char *detail)
{
    if (!detail || detail[0] == '\0') {
        return NULL;
    }
    if (strcmp(detail, "no error") == 0) {
        return NULL;
    }
    return detail;
}

static HFSWError
hfsw_ok(void)
{
    HFSWError err;
    err.code = 0;
    err.detail = NULL;
    return err;
}

static HFSWError
hfsw_err(const char *detail)
{
    HFSWError err;
    err.code = errno ? errno : EIO;
    err.detail = normalize_error_detail(detail);
    return err;
}

static int
hfsw_run_hfsck_core(const char *path)
{
    int nparts, pnum, result;
    int options = HFSCK_REPAIR | HFSCK_VERBOSE | HFSCK_YES;
    hfsvol vol;

    nparts = hfs_nparts(path);
    if (nparts == 0) {
        fprintf(stderr, "%s: partitioned medium contains no HFS partitions\n", path);
        return 1;
    }

    if (nparts > 1) {
        fprintf(stderr, "%s: must specify partition number (%d available)\n", path, nparts);
        return 1;
    } else if (nparts == -1) {
        pnum = 0;
    } else {
        pnum = 1;
    }

    v_init(&vol, HFS_OPT_NOCACHE);

    result = v_open(&vol, path, HFS_MODE_RDWR);
    if (result == -1) {
        vol.flags |= HFS_VOL_READONLY;
        result = v_open(&vol, path, HFS_MODE_RDONLY);
    }

    if (result == -1) {
        perror(path);
        return 1;
    }

    if (vol.flags & HFS_VOL_READONLY) {
        fprintf(stderr, "%s: warning: %s not writable; cannot repair\n", "hfsw_hfsck", path);
        options &= ~HFSCK_REPAIR;
    }

    if (v_geometry(&vol, pnum) == -1 || l_getmdb(&vol, &vol.mdb, 0) == -1) {
        perror(path);
        v_close(&vol);
        return 1;
    }

    result = hfsck(&vol, options);
    vol.flags |= HFS_VOL_MOUNTED;

    if (v_close(&vol) == -1) {
        perror("closing volume");
        return 1;
    }

    return result;
}

static HFSWError
resolve_hfs_partno_from_map_index(const char *path,
                                  int requestedPartno,
                                  int *outResolvedPartno)
{
    if (!path || !outResolvedPartno) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    if (requestedPartno <= 0) {
        *outResolvedPartno = requestedPartno;
        return hfsw_ok();
    }

    hfsvol vol;
    v_init(&vol, HFS_OPT_NOCACHE);
    if (v_open(&vol, path, HFS_MODE_RDONLY) == -1) {
        return hfsw_err(hfs_error);
    }

    Partition map;
    if (l_getpmentry(&vol, &map, 1) == -1) {
        v_close(&vol);
        return hfsw_err(hfs_error);
    }

    /* No valid partition map: let libhfs handle direct partition semantics. */
    if (map.pmSig != HFS_PM_SIGWORD) {
        v_close(&vol);
        *outResolvedPartno = requestedPartno;
        return hfsw_ok();
    }

    unsigned long total = (unsigned long)map.pmMapBlkCnt;
    int hfsOrdinal = 0;
    int found = 0;

    for (unsigned long bnum = 1; bnum <= total; ++bnum) {
        if (l_getpmentry(&vol, &map, bnum) == -1) {
            v_close(&vol);
            return hfsw_err(hfs_error);
        }

        if (strcmp((const char *)map.pmParType, "Apple_HFS") == 0) {
            ++hfsOrdinal;
        }

        if ((int)bnum == requestedPartno) {
            found = 1;
            break;
        }
    }

    if (v_close(&vol) == -1) {
        return hfsw_err(hfs_error);
    }

    if (!found || hfsOrdinal == 0) {
        errno = EINVAL;
        return hfsw_err("selected partition is not an HFS partition");
    }

    *outResolvedPartno = hfsOrdinal;
    return hfsw_ok();
}

static void
fill_file_info(const hfsdirent *e, HFSWFileInfo *out)
{
    memset(out, 0, sizeof(*out));

    /* Name (HFS_MAX_FLEN is 31; we have 255 bytes) */
    strncpy(out->name, e->name, sizeof(out->name) - 1);

    out->isDirectory  = (e->flags & HFS_ISDIR) ? 1 : 0;
    out->dataForkSize = (uint32_t)e->u.file.dsize;
    out->rsrcForkSize = (uint32_t)e->u.file.rsize;

    /* Type/creator are 4 chars + NUL in hfsdirent */
    strncpy(out->fileType,   e->u.file.type,    4);
    out->fileType[4] = '\0';
    strncpy(out->fileCreator, e->u.file.creator, 4);
    out->fileCreator[4] = '\0';

    out->flags    = (uint16_t)e->fdflags;
    out->created  = e->crdate;
    out->modified = e->mddate;
}

/* ---- Public API -------------------------------------------------------- */

HFSImage *
hfsw_open_image(const char *path, int readWrite)
{
    if (!path) {
        errno = EINVAL;
        return NULL;
    }

    int mode = readWrite ? 1 : 0; /* HFS_MODE_RDWR / HFS_MODE_RDONLY; libhfs uses 0/1 */
    hfsvol *vol = hfs_mount((char *)path, 0, mode);
    if (!vol) {
        /* libhfs sets errno / hfs_error */
        return NULL;
    }

    HFSImage *img = (HFSImage *)malloc(sizeof(HFSImage));
    if (!img) {
        hfs_umount(vol);
        errno = ENOMEM;
        return NULL;
    }

    img->vol = vol;
    return img;
}

HFSWOpenResult
hfsw_open_image_ex(const char *path, int readWrite, int partno)
{
    HFSWOpenResult result;
    result.image = NULL;
    result.error = hfsw_ok();

    if (!path) {
        errno = EINVAL;
        result.error = hfsw_err(NULL);
        return result;
    }

    if (partno < 0) {
        errno = EINVAL;
        result.error = hfsw_err(NULL);
        return result;
    }

    int resolvedPartno = 0;
    result.error = resolve_hfs_partno_from_map_index(path, partno, &resolvedPartno);
    if (result.error.code != 0) {
        return result;
    }

    int mode = readWrite ? 1 : 0; /* HFS_MODE_RDWR / HFS_MODE_RDONLY; libhfs uses 0/1 */
    hfsvol *vol = hfs_mount((char *)path, resolvedPartno, mode);
    if (!vol) {
        result.error = hfsw_err(hfs_error);
        return result;
    }

    HFSImage *img = (HFSImage *)malloc(sizeof(HFSImage));
    if (!img) {
        hfs_umount(vol);
        errno = ENOMEM;
        result.error = hfsw_err(NULL);
        return result;
    }

    img->vol = vol;
    result.image = img;
    return result;
}

void
hfsw_close_image(HFSImage *image)
{
    if (!image) return;

    if (image->vol) {
        hfs_umount(image->vol);
        image->vol = NULL;
    }
    free(image);
}

HFSWError
hfsw_hfsck(const char *path, int *outResult, char **outOutput)
{
    if (!path || !outResult || !outOutput) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    *outResult = 1;
    *outOutput = NULL;

    FILE *capture = tmpfile();
    if (!capture) {
        return hfsw_err("failed to create temporary capture file");
    }

    int captureFD = fileno(capture);
    int savedStdout = dup(STDOUT_FILENO);
    int savedStderr = dup(STDERR_FILENO);
    if (savedStdout == -1 || savedStderr == -1) {
        if (savedStdout != -1) close(savedStdout);
        if (savedStderr != -1) close(savedStderr);
        fclose(capture);
        return hfsw_err("failed to duplicate stdio handles");
    }

    if (dup2(captureFD, STDOUT_FILENO) == -1 || dup2(captureFD, STDERR_FILENO) == -1) {
        close(savedStdout);
        close(savedStderr);
        fclose(capture);
        return hfsw_err("failed to redirect stdio");
    }

    int result = hfsw_run_hfsck_core(path);

    fflush(stdout);
    fflush(stderr);

    int restoreErrno = 0;
    if (dup2(savedStdout, STDOUT_FILENO) == -1 || dup2(savedStderr, STDERR_FILENO) == -1) {
        restoreErrno = errno ? errno : EIO;
    }
    close(savedStdout);
    close(savedStderr);

    if (fseek(capture, 0, SEEK_END) != 0) {
        fclose(capture);
        errno = restoreErrno ? restoreErrno : errno;
        return hfsw_err("failed to size hfsck output");
    }

    long length = ftell(capture);
    if (length < 0) {
        fclose(capture);
        errno = restoreErrno ? restoreErrno : errno;
        return hfsw_err("failed to read hfsck output size");
    }

    if (fseek(capture, 0, SEEK_SET) != 0) {
        fclose(capture);
        errno = restoreErrno ? restoreErrno : errno;
        return hfsw_err("failed to rewind hfsck output");
    }

    size_t outLen = (size_t)length;
    char *buffer = (char *)malloc(outLen + 1);
    if (!buffer) {
        fclose(capture);
        errno = ENOMEM;
        return hfsw_err(NULL);
    }

    size_t nread = fread(buffer, 1, outLen, capture);
    fclose(capture);
    if (nread != outLen) {
        free(buffer);
        errno = EIO;
        return hfsw_err("failed to read captured hfsck output");
    }

    buffer[outLen] = '\0';
    *outOutput = buffer;
    *outResult = result;

    if (restoreErrno) {
        errno = restoreErrno;
        return hfsw_err("failed to restore stdio");
    }

    return hfsw_ok();
}

void
hfsw_free_string(char *ptr)
{
    free(ptr);
}

HFSWError
hfsw_create_blank_image(const char *path,
                        uint64_t sizeBytes,
                        const char *volumeName)
{
    if (!path || !volumeName) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    if (sizeBytes == 0) {
        errno = EINVAL;
        return hfsw_err("image size must be greater than zero");
    }

    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0666);
    if (fd == -1) {
        return hfsw_err("error creating image file");
    }

    if (ftruncate(fd, (off_t)sizeBytes) == -1) {
        int saved = errno;
        close(fd);
        errno = saved;
        return hfsw_err("error sizing image file");
    }

    if (close(fd) == -1) {
        return hfsw_err("error closing image file");
    }

    if (hfs_format(path, 0, HFS_OPT_NOCACHE, volumeName, 0, NULL) == -1) {
        return hfsw_err(hfs_error);
    }

    return hfsw_ok();
}

void
hfsw_set_debug_logging(int enabled)
{
    hfs_debug_logging_enabled = enabled ? 1 : 0;
}

int
hfsw_get_debug_logging(void)
{
    return hfs_debug_logging_enabled;
}

HFSWError
hfsw_list_partitions(const char *path,
                     hfsw_partition_callback callback,
                     void *context,
                     int *outHasPartitionMap)
{
    if (!path || !callback) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    if (outHasPartitionMap) {
        *outHasPartitionMap = 0;
    }

    hfsvol vol;
    v_init(&vol, HFS_OPT_NOCACHE);

    if (v_open(&vol, path, HFS_MODE_RDONLY) == -1) {
        return hfsw_err(hfs_error);
    }

    Partition map;
    if (l_getpmentry(&vol, &map, 1) == -1 ||
        map.pmSig != HFS_PM_SIGWORD) {
        v_close(&vol);
        return hfsw_ok();
    }

    if (outHasPartitionMap) {
        *outHasPartitionMap = 1;
    }

    unsigned long total = (unsigned long)map.pmMapBlkCnt;
    for (unsigned long bnum = 1; bnum <= total; ++bnum) {
        if (l_getpmentry(&vol, &map, bnum) == -1) {
            v_close(&vol);
            return hfsw_err(hfs_error);
        }

        HFSWPartitionInfo info;
        memset(&info, 0, sizeof(info));
        info.index = (int)bnum;
        strncpy(info.name, (const char *)map.pmPartName, sizeof(info.name) - 1);
        strncpy(info.type, (const char *)map.pmParType, sizeof(info.type) - 1);
        info.startBlock = (uint32_t)map.pmPyPartStart;
        info.blockCount = (uint32_t)map.pmPartBlkCnt;
        info.dataStart = (uint32_t)map.pmLgDataStart;
        info.dataCount = (uint32_t)map.pmDataCnt;
        info.isHFS = (strcmp(info.type, "Apple_HFS") == 0) ? 1 : 0;
        callback(&info, context);
    }

    if (v_close(&vol) == -1) {
        return hfsw_err(hfs_error);
    }

    return hfsw_ok();
}

HFSWError
hfsw_stat(HFSImage *image,
          const char *hfsPath,
          HFSWFileInfo *outInfo)
{
    if (!image || !image->vol || !hfsPath || !outInfo) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    hfsdirent ent;
    if (hfs_stat(image->vol, (char *)hfsPath, &ent) != 0) {
        /* errno set by libhfs */
        return hfsw_err(hfs_error);
    }

    fill_file_info(&ent, outInfo);
    return hfsw_ok();
}

HFSWError
hfsw_list_dir(HFSImage *image,
              const char *hfsDirPath,
              hfsw_list_callback callback,
              void *context)
{
    if (!image || !image->vol || !callback) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    const char *path = (hfsDirPath && hfsDirPath[0]) ? hfsDirPath : ":";

    hfsdir *dir = hfs_opendir(image->vol, (char *)path);
    if (!dir) {
        /* errno set by libhfs */
        return hfsw_err(hfs_error);
    }

    hfsdirent ent;
    while (hfs_readdir(dir, &ent) == 0) {
        HFSWFileInfo info;
        fill_file_info(&ent, &info);
        callback(&info, context);
    }

    hfs_closedir(dir);
    return hfsw_ok();
}

HFSWError
hfsw_volume_info(HFSImage *image,
                 HFSWVolumeInfo *outInfo)
{
    if (!image || !image->vol || !outInfo) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    hfsvolent ent;
    if (hfs_vstat(image->vol, &ent) != 0) {
        return hfsw_err(hfs_error);
    }

    memset(outInfo, 0, sizeof(*outInfo));
    strncpy(outInfo->name, ent.name, sizeof(outInfo->name) - 1);
    outInfo->flags = (uint32_t)ent.flags;
    outInfo->totalBytes = (uint64_t)ent.totbytes;
    outInfo->freeBytes = (uint64_t)ent.freebytes;
    outInfo->allocationBlockSize = (uint32_t)ent.alblocksz;
    outInfo->clumpSize = (uint32_t)ent.clumpsz;
    outInfo->numberOfFiles = (uint32_t)ent.numfiles;
    outInfo->numberOfDirectories = (uint32_t)ent.numdirs;
    outInfo->created = ent.crdate;
    outInfo->modified = ent.mddate;
    outInfo->backup = ent.bkdate;
    outInfo->blessedFolderId = (uint32_t)ent.blessed;

    return hfsw_ok();
}

HFSWError
hfsw_delete(HFSImage *image,
            const char *hfsPath)
{
    if (!image || !image->vol || !hfsPath) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    hfsdirent ent;
    if (hfs_stat(image->vol, (char *)hfsPath, &ent) != 0) {
        return hfsw_err(hfs_error);
    }

    if (ent.flags & HFS_ISDIR) {
        if (hfs_rmdir(image->vol, (char *)hfsPath) != 0) {
            return hfsw_err(hfs_error);
        }
    } else {
        if (hfs_delete(image->vol, (char *)hfsPath) != 0) {
            return hfsw_err(hfs_error);
        }
    }

    return hfsw_ok();
}

HFSWError
hfsw_rename(HFSImage *image,
            const char *hfsOldPath,
            const char *newName)
{
    if (!image || !image->vol || !hfsOldPath || !newName) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    if (newName[0] == '\0' || strchr(newName, ':') != NULL) {
        errno = EINVAL;
        return hfsw_err("new name must be a non-empty basename without ':'");
    }

    /* Keep the item in its current parent directory when renaming. */
    const char *lastColon = strrchr(hfsOldPath, ':');
    const char *parentPath = ":";
    char *parentOwned = NULL;

    if (lastColon != NULL) {
        if (lastColon != hfsOldPath) {
            size_t parentLen = (size_t)(lastColon - hfsOldPath);
            parentOwned = (char *)malloc(parentLen + 1);
            if (!parentOwned) {
                errno = ENOMEM;
                return hfsw_err(NULL);
            }
            memcpy(parentOwned, hfsOldPath, parentLen);
            parentOwned[parentLen] = '\0';
            parentPath = parentOwned;
        }
    }

    size_t parentLen = strlen(parentPath);
    int needsSep = (parentLen > 0 && parentPath[parentLen - 1] != ':');
    size_t destLen = parentLen + (needsSep ? 1 : 0) + strlen(newName) + 1;
    char *destPath = (char *)malloc(destLen);
    if (!destPath) {
        free(parentOwned);
        errno = ENOMEM;
        return hfsw_err(NULL);
    }

    if (needsSep) {
        snprintf(destPath, destLen, "%s:%s", parentPath, newName);
    } else {
        snprintf(destPath, destLen, "%s%s", parentPath, newName);
    }

    int result = hfs_rename(image->vol, (char *)hfsOldPath, destPath);
    free(parentOwned);
    free(destPath);
    if (result != 0) {
        return hfsw_err(hfs_error);
    }

    return hfsw_ok();
}

HFSWError
hfsw_move(HFSImage *image,
          const char *hfsOldPath,
          const char *newParentDirectory)
{
    if (!image || !image->vol || !hfsOldPath || !newParentDirectory) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    if (newParentDirectory[0] == '\0') {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    const char *baseName = strrchr(hfsOldPath, ':');
    baseName = baseName ? baseName + 1 : hfsOldPath;
    if (baseName[0] == '\0') {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    size_t parentLen = strlen(newParentDirectory);
    int needsSep = (parentLen > 0 && newParentDirectory[parentLen - 1] != ':');
    size_t destLen = parentLen + (needsSep ? 1 : 0) + strlen(baseName) + 1;

    char *destPath = (char *)malloc(destLen);
    if (!destPath) {
        errno = ENOMEM;
        return hfsw_err(NULL);
    }

    if (needsSep) {
        snprintf(destPath, destLen, "%s:%s", newParentDirectory, baseName);
    } else {
        snprintf(destPath, destLen, "%s%s", newParentDirectory, baseName);
    }

    int result = hfs_rename(image->vol, (char *)hfsOldPath, destPath);
    free(destPath);
    if (result != 0) {
        return hfsw_err(hfs_error);
    }

    return hfsw_ok();
}

HFSWError
hfsw_mkdir(HFSImage *image,
           const char *hfsDirPath)
{
    if (!image || !image->vol || !hfsDirPath) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    if (hfs_mkdir(image->vol, (char *)hfsDirPath) != 0) {
        return hfsw_err(hfs_error);
    }

    return hfsw_ok();
}

/* Helper: tidy 4-char Mac type/creator into char[5]. */
static void
normalize_fourcc(const char *in, char out[5])
{
    size_t len = in ? strlen(in) : 0;
    size_t i;

    for (i = 0; i < 4; ++i) {
        if (i < len) {
            out[i] = in[i];
        } else {
            out[i] = ' ';
        }
    }
    out[4] = '\0';
}

static int
hfsw_mode_to_hcopy_mode(int mode)
{
    switch (mode) {
        case HFSW_COPY_MODE_AUTO:
            return 'a';
        case HFSW_COPY_MODE_RAW:
            return 'r';
        case HFSW_COPY_MODE_MACB:
            return 'm';
        case HFSW_COPY_MODE_BINH:
            return 'b';
        case HFSW_COPY_MODE_TEXT:
            return 't';
        default:
            return 0;
    }
}

static int
hfsw_has_suffix_casefold(const char *value, const char *suffix)
{
    size_t valueLen, suffixLen;

    if (!value || !suffix) {
        return 0;
    }

    valueLen = strlen(value);
    suffixLen = strlen(suffix);
    if (valueLen < suffixLen) {
        return 0;
    }

    return strcasecmp(value + (valueLen - suffixLen), suffix) == 0;
}

static char *
hfsw_copyin_dest_with_decoded_suffix(const char *hfsDestPath, int resolvedMode)
{
    const char *suffix = NULL;
    const char *base;
    size_t prefixLen, baseLen, suffixLen, outLen;
    char *out;

    if (!hfsDestPath) {
        return NULL;
    }

    if (resolvedMode == 'm') {
        suffix = ".bin";
    } else if (resolvedMode == 'b') {
        suffix = ".hqx";
    } else {
        return NULL;
    }

    base = strrchr(hfsDestPath, ':');
    base = base ? base + 1 : hfsDestPath;

    if (base[0] == '\0' || !hfsw_has_suffix_casefold(base, suffix)) {
        return NULL;
    }

    prefixLen = (size_t)(base - hfsDestPath);
    baseLen = strlen(base);
    suffixLen = strlen(suffix);
    outLen = prefixLen + (baseLen - suffixLen) + 1;

    out = (char *)malloc(outLen);
    if (!out) {
        return NULL;
    }

    memcpy(out, hfsDestPath, prefixLen + (baseLen - suffixLen));
    out[prefixLen + (baseLen - suffixLen)] = '\0';
    return out;
}

HFSWError
hfsw_copy_in(HFSImage *image,
             const char *hostPath,
             const char *hfsDestPath,
             int mode)
{
    if (!image || !image->vol || !hostPath || !hfsDestPath) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    int hcopyMode = hfsw_mode_to_hcopy_mode(mode);
    int resolvedMode;
    if (hcopyMode == 0) {
        errno = EINVAL;
        return hfsw_err("unsupported copy mode");
    }

    resolvedMode = hcopyMode;
    if (resolvedMode == 'a') {
        cpifunc autoFunc = automode_unix(hostPath);
        if (autoFunc == cpi_macb) {
            resolvedMode = 'm';
        } else if (autoFunc == cpi_binh) {
            resolvedMode = 'b';
        } else if (autoFunc == cpi_text) {
            resolvedMode = 't';
        } else {
            resolvedMode = 'r';
        }
    }

    char *adjustedDest = hfsw_copyin_dest_with_decoded_suffix(hfsDestPath, resolvedMode);
    const char *effectiveDest = adjustedDest ? adjustedDest : hfsDestPath;

    char *sources[1];
    sources[0] = (char *)hostPath;
    const char *copyError = NULL;

    if (do_copyin(image->vol, 1, sources, effectiveDest, hcopyMode, &copyError) != 0) {
        free(adjustedDest);
        return hfsw_err(copyError);
    }

    free(adjustedDest);
    return hfsw_ok();
}

HFSWError
hfsw_copy_out(HFSImage *image,
              const char *hfsPath,
              const char *hostDestPath,
              int mode)
{
    if (!image || !image->vol || !hfsPath || !hostDestPath) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    int hcopyMode = hfsw_mode_to_hcopy_mode(mode);
    if (hcopyMode == 0) {
        errno = EINVAL;
        return hfsw_err("unsupported copy mode");
    }

    char *sources[1];
    sources[0] = (char *)hfsPath;
    const char *copyError = NULL;

    if (do_copyout(image->vol, 1, sources, hostDestPath, hcopyMode, &copyError) != 0) {
        return hfsw_err(copyError);
    }

    return hfsw_ok();
}

HFSWError
hfsw_read_fork(HFSImage *image,
               const char *hfsPath,
               int forkKind,
               uint8_t **outBytes,
               uint32_t *outSize)
{
    if (!image || !image->vol || !hfsPath || !outBytes || !outSize) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    if (forkKind != HFSW_FORK_DATA && forkKind != HFSW_FORK_RESOURCE) {
        errno = EINVAL;
        return hfsw_err("invalid fork kind");
    }

    *outBytes = NULL;
    *outSize = 0;

    hfsfile *const file = hfs_open(image->vol, hfsPath);
    if (!file) {
        return hfsw_err(hfs_error);
    }

    if (hfs_setfork(file, forkKind) != 0) {
        hfs_close(file);
        return hfsw_err(hfs_error);
    }

    hfsdirent ent;
    if (hfs_fstat(file, &ent) != 0) {
        hfs_close(file);
        return hfsw_err(hfs_error);
    }

    const unsigned long expected = (forkKind == HFSW_FORK_RESOURCE) ? ent.u.file.rsize : ent.u.file.dsize;
    if (expected == 0) {
        hfs_close(file);
        return hfsw_ok();
    }

    uint8_t *const buffer = malloc(expected);
    if (!buffer) {
        hfs_close(file);
        errno = ENOMEM;
        return hfsw_err(NULL);
    }

    unsigned long offset = 0;
    while (offset < expected) {
        const unsigned long got = hfs_read(file, buffer + offset, expected - offset);
        if (got == 0) {
            free(buffer);
            hfs_close(file);
            errno = EIO;
            return hfsw_err("error reading HFS fork");
        }
        offset += got;
    }

    if (hfs_close(file) != 0) {
        free(buffer);
        return hfsw_err(hfs_error);
    }

    *outBytes = buffer;
    *outSize = (uint32_t)expected;
    return hfsw_ok();
}

HFSWError
hfsw_write_fork(HFSImage *image,
                const char *hfsPath,
                int forkKind,
                const uint8_t *bytes,
                uint32_t size)
{
    if (!image || !image->vol || !hfsPath) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    if (size > 0 && !bytes) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    if (forkKind != HFSW_FORK_DATA && forkKind != HFSW_FORK_RESOURCE) {
        errno = EINVAL;
        return hfsw_err("invalid fork kind");
    }

    hfsfile *file = hfs_open(image->vol, hfsPath);
    if (!file && errno == ENOENT) {
        file = hfs_create(image->vol, hfsPath, "????", "UNIX");
    }
    if (!file) {
        return hfsw_err(hfs_error);
    }

    if (hfs_setfork(file, forkKind) != 0) {
        hfs_close(file);
        return hfsw_err(hfs_error);
    }

    if (hfs_truncate(file, 0) != 0) {
        hfs_close(file);
        return hfsw_err(hfs_error);
    }

    unsigned long offset = 0;
    while (offset < (unsigned long)size) {
        const unsigned long wrote = hfs_write(file, bytes + offset, (unsigned long)size - offset);
        if (wrote == 0) {
            hfs_close(file);
            errno = EIO;
            return hfsw_err("error writing HFS fork");
        }
        offset += wrote;
    }

    if (hfs_close(file) != 0) {
        return hfsw_err(hfs_error);
    }

    return hfsw_ok();
}

HFSWError
hfsw_set_type_creator(HFSImage *image,
                      const char *hfsPath,
                      const char *fileType,
                      const char *fileCreator)
{
    if (!image || !image->vol || !hfsPath) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    hfsdirent ent;
    if (hfs_stat(image->vol, (char *)hfsPath, &ent) != 0) {
        return hfsw_err(hfs_error);
    }

    normalize_fourcc(fileType,   ent.u.file.type);
    normalize_fourcc(fileCreator, ent.u.file.creator);

    if (hfs_setattr(image->vol, (char *)hfsPath, &ent) != 0) {
        return hfsw_err(hfs_error);
    }

    return hfsw_ok();
}

HFSWError
hfsw_set_finder_info(HFSImage *image,
                     const char *hfsPath,
                     uint16_t finderFlags,
                     int64_t created,
                     int64_t modified)
{
    if (!image || !image->vol || !hfsPath) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    hfsdirent ent;
    if (hfs_stat(image->vol, (char *)hfsPath, &ent) != 0) {
        return hfsw_err(hfs_error);
    }

    ent.fdflags = finderFlags;
    ent.crdate = (time_t)created;
    ent.mddate = (time_t)modified;

    if (hfs_setattr(image->vol, (char *)hfsPath, &ent) != 0) {
        return hfsw_err(hfs_error);
    }

    return hfsw_ok();
}

HFSWError
hfsw_set_blessed(HFSImage *image,
                 const char *hfsPath)
{
    if (!image || !image->vol || !hfsPath) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    hfsdirent dirEnt;
    if (hfs_stat(image->vol, (char *)hfsPath, &dirEnt) != 0) {
        return hfsw_err(hfs_error);
    }

    if (!(dirEnt.flags & HFS_ISDIR)) {
        errno = ENOTDIR;
        return hfsw_err("blessed path must be a directory");
    }

    hfsvolent volEnt;
    if (hfs_vstat(image->vol, &volEnt) != 0) {
        return hfsw_err(hfs_error);
    }

    volEnt.blessed = dirEnt.cnid;
    if (hfs_vsetattr(image->vol, &volEnt) != 0) {
        return hfsw_err(hfs_error);
    }

    return hfsw_ok();
}

HFSWError
hfsw_test_binhex_encode_file(const char *inputPath,
                             const char *outputPath)
{
    if (!inputPath || !outputPath) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    int inFD = open(inputPath, O_RDONLY);
    if (inFD == -1) {
        return hfsw_err("failed to open BinHex encode input");
    }

    int outFD = open(outputPath, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (outFD == -1) {
        int saved = errno;
        close(inFD);
        errno = saved;
        return hfsw_err("failed to open BinHex encode output");
    }

    bh_context bh;
    bh_init(&bh);

    if (bh_start(&bh, outFD) == -1) {
        int saved = errno;
        close(inFD);
        close(outFD);
        errno = saved;
        return hfsw_err(bh_get_error(&bh));
    }

    unsigned char buffer[4096];
    int failed = 0;
    while (1) {
        ssize_t nread = read(inFD, buffer, sizeof(buffer));
        if (nread == 0) {
            break;
        }
        if (nread < 0) {
            failed = 1;
            errno = EIO;
            break;
        }
        if (bh_insert(&bh, buffer, (int)nread) == -1) {
            failed = 1;
            break;
        }
    }

    if (!failed && bh_insertcrc(&bh) == -1) {
        failed = 1;
    }
    if (bh_end(&bh) == -1) {
        failed = 1;
    }

    close(inFD);
    close(outFD);

    if (failed) {
        return hfsw_err(bh_get_error(&bh));
    }

    return hfsw_ok();
}

HFSWError
hfsw_test_binhex_decode_file(const char *inputPath,
                             const char *outputPath,
                             size_t decodedLength)
{
    if (!inputPath || !outputPath) {
        errno = EINVAL;
        return hfsw_err(NULL);
    }

    int inFD = open(inputPath, O_RDONLY);
    if (inFD == -1) {
        return hfsw_err("failed to open BinHex decode input");
    }

    int outFD = open(outputPath, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (outFD == -1) {
        int saved = errno;
        close(inFD);
        errno = saved;
        return hfsw_err("failed to open BinHex decode output");
    }

    bh_context bh;
    bh_init(&bh);

    if (bh_open(&bh, inFD) == -1) {
        int saved = errno;
        close(inFD);
        close(outFD);
        errno = saved;
        return hfsw_err(bh_get_error(&bh));
    }

    unsigned char buffer[4096];
    size_t remaining = decodedLength;
    int failed = 0;

    while (remaining > 0) {
        int chunk = (remaining > sizeof(buffer)) ? (int)sizeof(buffer) : (int)remaining;
        int nread = bh_read(&bh, buffer, chunk);
        if (nread != chunk) {
            failed = 1;
            break;
        }
        if (write(outFD, buffer, (size_t)nread) != nread) {
            failed = 1;
            errno = EIO;
            break;
        }
        remaining -= (size_t)nread;
    }

    if (!failed && bh_readcrc(&bh) == -1) {
        failed = 1;
    }
    if (bh_close(&bh) == -1) {
        failed = 1;
    }

    close(inFD);
    close(outFD);

    if (failed) {
        return hfsw_err(bh_get_error(&bh));
    }

    return hfsw_ok();
}
