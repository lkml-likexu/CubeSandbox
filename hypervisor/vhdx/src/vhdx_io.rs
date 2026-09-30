// Copyright © 2021 Intel Corporation
//
// SPDX-License-Identifier: Apache-2.0

use crate::vhdx_bat::{self, BatEntry, VhdxBatError};
use crate::vhdx_metadata::{self, DiskSpec};
use remain::sorted;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};
use thiserror::Error;

#[sorted]
#[derive(Error, Debug)]
pub enum VhdxIoError {
    #[error("Invalid BAT entry state")]
    InvalidBatEntryState,
    #[error("Invalid BAT entry count")]
    InvalidBatIndex,
    #[error("Invalid buffer size")]
    InvalidBufferSize,
    #[error("Invalid disk size")]
    InvalidDiskSize,
    #[error("Failed reading sector blocks from file {0}")]
    ReadSectorBlock(#[source] io::Error),
    #[error("Failed changing file length {0}")]
    ResizeFile(#[source] io::Error),
    #[error("Differencing mode is not supported yet")]
    UnsupportedMode,
    #[error("Failed writing BAT to file {0}")]
    WriteBat(#[source] VhdxBatError),
}

pub type Result<T> = std::result::Result<T, VhdxIoError>;

macro_rules! align {
    ($n:expr, $align:expr) => {{
        (($n + $align - 1) / $align) * $align
    }};
}

#[derive(Default)]
struct Sector {
    bat_index: u64,
    free_sectors: u64,
    free_bytes: u64,
    file_offset: u64,
    block_offset: u64,
}

impl Sector {
    /// Translate sector index and count of data in file to actual offsets and
    /// BAT index.
    pub fn new(
        disk_spec: &DiskSpec,
        bat: &[BatEntry],
        sector_index: u64,
        sector_count: u64,
    ) -> Result<Sector> {
        let mut sector = Sector::default();

        let payload_index = sector_index / disk_spec.sectors_per_block as u64;
        let bitmap_entries = payload_index
            .checked_div(disk_spec.chunk_ratio)
            .ok_or(VhdxIoError::InvalidBatIndex)?;
        sector.bat_index = payload_index
            .checked_add(bitmap_entries)
            .ok_or(VhdxIoError::InvalidBatIndex)?;
        sector.block_offset = sector_index % disk_spec.sectors_per_block as u64;
        sector.free_sectors = disk_spec.sectors_per_block as u64 - sector.block_offset;
        if sector.free_sectors > sector_count {
            sector.free_sectors = sector_count;
        }

        sector.free_bytes = sector.free_sectors * disk_spec.logical_sector_size as u64;
        sector.block_offset *= disk_spec.logical_sector_size as u64;

        let bat_entry = match bat.get(sector.bat_index as usize) {
            Some(entry) => entry.0,
            None => {
                return Err(VhdxIoError::InvalidBatIndex);
            }
        };
        sector.file_offset = bat_entry & vhdx_bat::BAT_FILE_OFF_MASK;
        if sector.file_offset != 0 {
            sector.file_offset += sector.block_offset;
        }

        Ok(sector)
    }
}

/// VHDx IO read routine: requires relative sector index and count for the
/// requested data.
pub fn read(
    f: &mut File,
    buf: &mut [u8],
    disk_spec: &DiskSpec,
    bat: &[BatEntry],
    mut sector_index: u64,
    mut sector_count: u64,
) -> Result<usize> {
    let mut read_count: usize = 0;

    while sector_count > 0 {
        if disk_spec.has_parent {
            return Err(VhdxIoError::UnsupportedMode);
        } else {
            let sector = Sector::new(disk_spec, bat, sector_index, sector_count)?;

            let bat_entry = match bat.get(sector.bat_index as usize) {
                Some(entry) => entry.0,
                None => {
                    return Err(VhdxIoError::InvalidBatIndex);
                }
            };

            let bytes =
                usize::try_from(sector.free_bytes).map_err(|_| VhdxIoError::InvalidBufferSize)?;
            let end = read_count
                .checked_add(bytes)
                .ok_or(VhdxIoError::InvalidBufferSize)?;
            let destination = buf
                .get_mut(read_count..end)
                .ok_or(VhdxIoError::InvalidBufferSize)?;

            match bat_entry & vhdx_bat::BAT_STATE_BIT_MASK {
                vhdx_bat::PAYLOAD_BLOCK_NOT_PRESENT
                | vhdx_bat::PAYLOAD_BLOCK_UNDEFINED
                | vhdx_bat::PAYLOAD_BLOCK_UNMAPPED
                | vhdx_bat::PAYLOAD_BLOCK_ZERO => destination.fill(0),
                vhdx_bat::PAYLOAD_BLOCK_FULLY_PRESENT => {
                    f.seek(SeekFrom::Start(sector.file_offset))
                        .map_err(VhdxIoError::ReadSectorBlock)?;
                    f.read_exact(destination)
                        .map_err(VhdxIoError::ReadSectorBlock)?;
                }
                vhdx_bat::PAYLOAD_BLOCK_PARTIALLY_PRESENT => {
                    return Err(VhdxIoError::UnsupportedMode);
                }
                _ => {
                    return Err(VhdxIoError::InvalidBatEntryState);
                }
            };
            sector_count -= sector.free_sectors;
            sector_index += sector.free_sectors;
            read_count = end;
        };
    }
    Ok(read_count)
}

/// VHDx IO write routine: requires relative sector index and count for the
/// requested data.
pub fn write(
    f: &mut File,
    buf: &[u8],
    disk_spec: &mut DiskSpec,
    bat_offset: u64,
    bat: &mut [BatEntry],
    mut sector_index: u64,
    mut sector_count: u64,
) -> Result<usize> {
    let mut write_count: usize = 0;

    while sector_count > 0 {
        if disk_spec.has_parent {
            return Err(VhdxIoError::UnsupportedMode);
        } else {
            let sector = Sector::new(disk_spec, bat, sector_index, sector_count)?;

            let bat_entry = match bat.get(sector.bat_index as usize) {
                Some(entry) => entry.0,
                None => {
                    return Err(VhdxIoError::InvalidBatIndex);
                }
            };

            let bytes =
                usize::try_from(sector.free_bytes).map_err(|_| VhdxIoError::InvalidBufferSize)?;
            let end = write_count
                .checked_add(bytes)
                .ok_or(VhdxIoError::InvalidBufferSize)?;
            let source = buf
                .get(write_count..end)
                .ok_or(VhdxIoError::InvalidBufferSize)?;

            match bat_entry & vhdx_bat::BAT_STATE_BIT_MASK {
                vhdx_bat::PAYLOAD_BLOCK_NOT_PRESENT
                | vhdx_bat::PAYLOAD_BLOCK_UNDEFINED
                | vhdx_bat::PAYLOAD_BLOCK_UNMAPPED
                | vhdx_bat::PAYLOAD_BLOCK_ZERO => {
                    let file_offset =
                        align!(disk_spec.image_size, vhdx_metadata::BLOCK_SIZE_MIN as u64);
                    let new_size = file_offset
                        .checked_add(disk_spec.block_size as u64)
                        .ok_or(VhdxIoError::InvalidDiskSize)?;

                    f.set_len(new_size).map_err(VhdxIoError::ResizeFile)?;
                    disk_spec.image_size = new_size;

                    let new_bat_entry = file_offset
                        | (vhdx_bat::PAYLOAD_BLOCK_FULLY_PRESENT & vhdx_bat::BAT_STATE_BIT_MASK);
                    bat[sector.bat_index as usize] = BatEntry(new_bat_entry);
                    BatEntry::write_bat_entries(f, bat_offset, bat)
                        .map_err(VhdxIoError::WriteBat)?;

                    if file_offset < vhdx_metadata::BLOCK_SIZE_MIN as u64 {
                        break;
                    }

                    f.seek(SeekFrom::Start(file_offset + sector.block_offset))
                        .map_err(VhdxIoError::ReadSectorBlock)?;
                    f.write_all(source).map_err(VhdxIoError::ReadSectorBlock)?;
                }
                vhdx_bat::PAYLOAD_BLOCK_FULLY_PRESENT => {
                    if sector.file_offset < vhdx_metadata::BLOCK_SIZE_MIN as u64 {
                        break;
                    }

                    f.seek(SeekFrom::Start(sector.file_offset))
                        .map_err(VhdxIoError::ReadSectorBlock)?;
                    f.write_all(source).map_err(VhdxIoError::ReadSectorBlock)?;
                }
                vhdx_bat::PAYLOAD_BLOCK_PARTIALLY_PRESENT => {
                    return Err(VhdxIoError::UnsupportedMode);
                }
                _ => {
                    return Err(VhdxIoError::InvalidBatEntryState);
                }
            };
            sector_count -= sector.free_sectors;
            sector_index += sector.free_sectors;
            write_count = end;
        };
    }
    Ok(write_count)
}

#[cfg(test)]
mod tests {
    use super::{read, write, DiskSpec, VhdxIoError};
    use crate::vhdx_bat::{BatEntry, PAYLOAD_BLOCK_FULLY_PRESENT, PAYLOAD_BLOCK_UNMAPPED};
    use std::fs::{self, File, OpenOptions};
    use std::io::{Read, Seek, SeekFrom, Write};
    use std::path::PathBuf;

    const BLOCK_SIZE: u64 = 1 << 20;
    const SECTOR_SIZE: usize = 512;

    fn temporary_file(name: &str) -> (PathBuf, File) {
        let path = std::env::temp_dir().join(format!(
            "vhdx-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)
            .unwrap();
        (path, file)
    }

    fn disk_spec(image_size: u64) -> DiskSpec {
        DiskSpec {
            image_size,
            block_size: BLOCK_SIZE as u32,
            sectors_per_block: 2,
            logical_sector_size: SECTOR_SIZE as u32,
            chunk_ratio: u64::MAX,
            ..DiskSpec::default()
        }
    }

    fn present(offset: u64) -> BatEntry {
        BatEntry(offset | PAYLOAD_BLOCK_FULLY_PRESENT)
    }

    #[test]
    fn sector_accounts_for_bitmap_bat_entries() {
        let spec = DiskSpec {
            sectors_per_block: 2,
            logical_sector_size: SECTOR_SIZE as u32,
            chunk_ratio: 2,
            ..DiskSpec::default()
        };
        let bat = [
            present(BLOCK_SIZE),
            present(2 * BLOCK_SIZE),
            BatEntry(PAYLOAD_BLOCK_UNMAPPED),
            present(3 * BLOCK_SIZE),
        ];

        let sector = super::Sector::new(&spec, &bat, 4, 1).unwrap();
        assert_eq!(sector.bat_index, 3);
        assert_eq!(sector.file_offset, 3 * BLOCK_SIZE);
    }

    #[test]
    fn read_advances_across_present_and_unmapped_blocks() {
        let (path, mut file) = temporary_file("read-blocks");
        file.set_len(4 * BLOCK_SIZE).unwrap();
        file.seek(SeekFrom::Start(BLOCK_SIZE + SECTOR_SIZE as u64))
            .unwrap();
        file.write_all(&vec![b'a'; SECTOR_SIZE]).unwrap();
        file.seek(SeekFrom::Start(3 * BLOCK_SIZE)).unwrap();
        file.write_all(&vec![b'c'; SECTOR_SIZE]).unwrap();

        let spec = disk_spec(4 * BLOCK_SIZE);
        let bat = [
            present(BLOCK_SIZE),
            BatEntry(PAYLOAD_BLOCK_UNMAPPED),
            present(3 * BLOCK_SIZE),
        ];
        let mut buf = vec![b'x'; 4 * SECTOR_SIZE];

        assert_eq!(
            read(&mut file, &mut buf, &spec, &bat, 1, 4).unwrap(),
            buf.len()
        );
        assert_eq!(&buf[..SECTOR_SIZE], vec![b'a'; SECTOR_SIZE]);
        assert_eq!(&buf[SECTOR_SIZE..3 * SECTOR_SIZE], vec![0; 2 * SECTOR_SIZE]);
        assert_eq!(&buf[3 * SECTOR_SIZE..], vec![b'c'; SECTOR_SIZE]);

        drop(file);
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn write_advances_across_payload_blocks() {
        let (path, mut file) = temporary_file("write-blocks");
        file.set_len(3 * BLOCK_SIZE).unwrap();
        let mut spec = disk_spec(3 * BLOCK_SIZE);
        let mut bat = [present(BLOCK_SIZE), present(2 * BLOCK_SIZE)];
        let mut buf = vec![b'a'; SECTOR_SIZE];
        buf.extend(vec![b'b'; 2 * SECTOR_SIZE]);

        assert_eq!(
            write(&mut file, &buf, &mut spec, 0, &mut bat, 1, 3).unwrap(),
            buf.len()
        );

        let mut first = vec![0; SECTOR_SIZE];
        file.seek(SeekFrom::Start(BLOCK_SIZE + SECTOR_SIZE as u64))
            .unwrap();
        file.read_exact(&mut first).unwrap();
        let mut second = vec![0; 2 * SECTOR_SIZE];
        file.seek(SeekFrom::Start(2 * BLOCK_SIZE)).unwrap();
        file.read_exact(&mut second).unwrap();
        assert_eq!(first, vec![b'a'; SECTOR_SIZE]);
        assert_eq!(second, vec![b'b'; 2 * SECTOR_SIZE]);

        drop(file);
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn rejects_buffers_smaller_than_the_sector_range() {
        let (path, mut file) = temporary_file("short-buffer");
        file.set_len(2 * BLOCK_SIZE).unwrap();
        let spec = disk_spec(2 * BLOCK_SIZE);
        let bat = [present(BLOCK_SIZE)];
        let mut buf = vec![0; SECTOR_SIZE - 1];

        assert!(matches!(
            read(&mut file, &mut buf, &spec, &bat, 0, 1),
            Err(VhdxIoError::InvalidBufferSize)
        ));

        drop(file);
        fs::remove_file(path).unwrap();
    }
}
