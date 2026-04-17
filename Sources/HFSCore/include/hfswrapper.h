// hfswrapper.h
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

#ifndef HFSWRAPPER_H
#define HFSWRAPPER_H

#include <stdint.h>
#include <time.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Forward declaration of libhfs types (we don't expose them directly). */
struct _hfsvol_;
typedef struct _hfsvol_ hfsvol;

/* Opaque-ish handle to an open HFS image */
typedef struct HFSImage {
    hfsvol *vol;
} HFSImage;

/* Error information returned by hfsw_* calls. */
typedef struct {
    int code;                 /* 0 on success, otherwise errno */
    const char *detail;       /* libhfs/hfsutils detail or NULL */
} HFSWError;

typedef struct {
    int index;                /* partition map entry number (1-based) */
    char name[33];            /* partition name */
    char type[33];            /* partition type */
    uint32_t startBlock;      /* physical start block */
    uint32_t blockCount;      /* physical block count */
    uint32_t dataStart;       /* logical data start */
    uint32_t dataCount;       /* logical data block count */
    int isHFS;                /* nonzero if Apple_HFS */
} HFSWPartitionInfo;

typedef void (*hfsw_partition_callback)(
    const HFSWPartitionInfo *info,
    void *context
);

/* Result for hfsw_open_image_ex. */
typedef struct {
    HFSImage *image;          /* NULL on failure */
    HFSWError error;          /* error info if image is NULL */
} HFSWOpenResult;

/* Copy modes mirroring hcopy (-a/-r/-m/-b/-t). */
#define HFSW_COPY_MODE_AUTO 0
#define HFSW_COPY_MODE_RAW  1
#define HFSW_COPY_MODE_MACB 2
#define HFSW_COPY_MODE_BINH 3
#define HFSW_COPY_MODE_TEXT 4

/* HFS fork selectors for hfsw_read_fork/hfsw_write_fork. */
#define HFSW_FORK_DATA      0
#define HFSW_FORK_RESOURCE  1

/* File information returned by hfsw_stat() and hfsw_list_dir() */
typedef struct {
    char      name[256];    /* UTF-8-ish name, up to 255 bytes plus NUL */
    int       isDirectory;  /* nonzero if directory */
    uint32_t  dataForkSize; /* bytes */
    uint32_t  rsrcForkSize; /* bytes */
    char      fileType[5];  /* 4-char type + NUL */
    char      fileCreator[5]; /* 4-char creator + NUL */
    uint16_t  flags;        /* Finder flags, HFS_FNDR_* */
    time_t    created;      /* creation time */
    time_t    modified;     /* modification time */
} HFSWFileInfo;

/* Volume information returned by hfsw_volume_info() */
typedef struct {
    char      name[256];
    uint32_t  flags;
    uint64_t  totalBytes;
    uint64_t  freeBytes;
    uint32_t  allocationBlockSize;
    uint32_t  clumpSize;
    uint32_t  numberOfFiles;
    uint32_t  numberOfDirectories;
    time_t    created;
    time_t    modified;
    time_t    backup;
    uint32_t  blessedFolderId;
} HFSWVolumeInfo;

/* Callback type used when listing directories. */
typedef void (*hfsw_list_callback)(
    const HFSWFileInfo *info,
    void *context
);

/* Open a disk image (HFS volume).
 * path: POSIX path to disk image or block device.
 * readWrite: 0 = read-only, nonzero = read/write.
 * Returns NULL on failure.
 */
HFSImage *hfsw_open_image(const char *path, int readWrite);

/* Open a disk image and return error information if it fails.
 * partno: 0 for whole-device mount; otherwise partition-map entry index.
 */
HFSWOpenResult hfsw_open_image_ex(const char *path, int readWrite, int partno);

/* Flush + close the image, freeing resources. */
void hfsw_close_image(HFSImage *image);

/* Create a new blank raw image file and format it as a single HFS volume. */
HFSWError hfsw_create_blank_image(const char *path,
                                  uint64_t sizeBytes,
                                  const char *volumeName);

/* Run hfsck with repair+verbose behavior and return captured text output.
 * outResult receives hfsck's return code (0 = clean/success, nonzero = issues).
 * outOutput receives a malloc-allocated C string that must be freed with
 * hfsw_free_string().
 */
HFSWError hfsw_hfsck(const char *path, int *outResult, char **outOutput);

/* Free strings allocated by hfswrapper APIs (e.g. hfsw_hfsck output). */
void hfsw_free_string(char *ptr);

/* BinHex test helpers used by unit tests. */
HFSWError hfsw_test_binhex_encode_file(const char *inputPath,
                                       const char *outputPath);
HFSWError hfsw_test_binhex_decode_file(const char *inputPath,
                                       const char *outputPath,
                                       size_t decodedLength);

/* Enable/disable libhfs diagnostic logging (e.g. BLOCK: READ/WRITE). */
void hfsw_set_debug_logging(int enabled);
int hfsw_get_debug_logging(void);

/* List partitions in a disk image.
 * Sets outHasPartitionMap to 1 if a map is present.
 */
HFSWError hfsw_list_partitions(const char *path,
                               hfsw_partition_callback callback,
                               void *context,
                               int *outHasPartitionMap);

/* Get info for a given HFS path (e.g. ":System Folder:Finder"). */
HFSWError hfsw_stat(HFSImage *image,
                    const char *hfsPath,
                    HFSWFileInfo *outInfo);

/* List contents of a directory.
 * hfsDirPath: HFS path to a directory (":" for root).
 * Calls callback once per entry.
 */
HFSWError hfsw_list_dir(HFSImage *image,
                        const char *hfsDirPath,
                        hfsw_list_callback callback,
                        void *context);

/* Get volume statistics (total/free bytes, counts, timestamps). */
HFSWError hfsw_volume_info(HFSImage *image,
                           HFSWVolumeInfo *outInfo);

/* Delete file or (empty) directory at hfsPath. */
HFSWError hfsw_delete(HFSImage *image,
                      const char *hfsPath);

/* Rename file or directory.
 * hfsOldPath: existing path.
 * newName: new name only (no path separators).
 */
HFSWError hfsw_rename(HFSImage *image,
                      const char *hfsOldPath,
                      const char *newName);

/* Move file or directory to a new parent directory.
 * hfsOldPath: existing path.
 * newParentDirectory: destination directory path (":" for root).
 */
HFSWError hfsw_move(HFSImage *image,
                    const char *hfsOldPath,
                    const char *newParentDirectory);

/* Create a directory at hfsDirPath (one level). */
HFSWError hfsw_mkdir(HFSImage *image,
                     const char *hfsDirPath);

/* Copy a host file (POSIX path) into the HFS image.
 * hostPath: POSIX path to existing file.
 * hfsDestPath: full HFS destination path INCLUDING filename.
 * mode: HFSW_COPY_MODE_AUTO/HFSW_COPY_MODE_RAW/HFSW_COPY_MODE_MACB/
 *       HFSW_COPY_MODE_BINH/HFSW_COPY_MODE_TEXT.
 */
HFSWError hfsw_copy_in(HFSImage *image,
                       const char *hostPath,
                       const char *hfsDestPath,
                       int mode);

/* Copy an HFS file to the host filesystem.
 * hfsPath: full HFS path to file.
 * hostDestPath: POSIX path to create/overwrite.
 * mode: HFSW_COPY_MODE_AUTO/HFSW_COPY_MODE_RAW/HFSW_COPY_MODE_MACB/
 *       HFSW_COPY_MODE_BINH/HFSW_COPY_MODE_TEXT.
 */
HFSWError hfsw_copy_out(HFSImage *image,
                        const char *hfsPath,
                        const char *hostDestPath,
                        int mode);

/* Read a fork of an HFS file.
 * Caller must free the buffer on success.
 */
HFSWError hfsw_read_fork(HFSImage *image,
                         const char *hfsPath,
                         int forkKind,
                         uint8_t **outBytes,
                         uint32_t *outSize);

/* Write a fork of an HFS file. */
HFSWError hfsw_write_fork(HFSImage *image,
                          const char *hfsPath,
                          int forkKind,
                          const uint8_t *bytes,
                          uint32_t size);

/* Set Mac file type and creator for an HFS file.
 * fileType/fileCreator: 4-character codes (e.g. "TEXT", "ttxt").
 * If shorter, will be padded with spaces; if longer, truncated.
 */
HFSWError hfsw_set_type_creator(HFSImage *image,
                                const char *hfsPath,
                                const char *fileType,
                                const char *fileCreator);

/* Set Finder flags and create/modify timestamps for an HFS file. */
HFSWError hfsw_set_finder_info(HFSImage *image,
                               const char *hfsPath,
                               uint16_t finderFlags,
                               int64_t created,
                               int64_t modified);

/* Set the volume blessed folder to the directory at hfsPath. */
HFSWError hfsw_set_blessed(HFSImage *image,
                           const char *hfsPath);

#ifdef __cplusplus
}
#endif

#endif /* HFSWRAPPER_H */
