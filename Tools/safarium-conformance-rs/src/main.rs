#![forbid(unsafe_code)]

use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::path::Path;
use std::process::ExitCode;

// ============================================================================
// Minimal Zero-Dependency JSON AST & Serializer
// ============================================================================

#[derive(Debug, Clone, PartialEq)]
enum JsonVal {
    Null,
    Bool(bool),
    UInt(u64),
    Float(f64),
    Str(String),
    Arr(Vec<JsonVal>),
    Obj(Vec<(String, JsonVal)>),
}

impl JsonVal {
    fn to_json_string(&self) -> String {
        let mut out = String::new();
        self.write_to(&mut out);
        out
    }

    fn write_to(&self, out: &mut String) {
        match self {
            JsonVal::Null => out.push_str("null"),
            JsonVal::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            JsonVal::UInt(n) => out.push_str(&n.to_string()),
            JsonVal::Float(f) => {
                if f.is_finite() {
                    out.push_str(&format!("{:.6}", f));
                } else {
                    out.push_str("null");
                }
            }
            JsonVal::Str(s) => write_json_str(s, out),
            JsonVal::Arr(items) => {
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.write_to(out);
                }
                out.push(']');
            }
            JsonVal::Obj(entries) => {
                out.push('{');
                for (i, (k, v)) in entries.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write_json_str(k, out);
                    out.push(':');
                    v.write_to(out);
                }
                out.push('}');
            }
        }
    }
}

fn write_json_str(s: &str, out: &mut String) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

// ============================================================================
// Common Conformance Report
// ============================================================================

#[derive(Debug, Clone)]
struct ConformanceReport {
    passed: bool,
    format: String,
    violations: Vec<String>,
    details: JsonVal,
}

impl ConformanceReport {
    fn to_json(&self) -> String {
        let root = JsonVal::Obj(vec![
            ("passed".to_string(), JsonVal::Bool(self.passed)),
            ("format".to_string(), JsonVal::Str(self.format.clone())),
            (
                "violations".to_string(),
                JsonVal::Arr(
                    self.violations
                        .iter()
                        .map(|v| JsonVal::Str(v.clone()))
                        .collect(),
                ),
            ),
            ("details".to_string(), self.details.clone()),
        ]);
        root.to_json_string()
    }
}

// ============================================================================
// Safe Byte Reading Helpers
// ============================================================================

fn read_u16_be(data: &[u8], off: usize) -> Option<u16> {
    let slice = data.get(off..off.checked_add(2)?)?;
    Some(u16::from_be_bytes([slice[0], slice[1]]))
}

fn read_u32_be(data: &[u8], off: usize) -> Option<u32> {
    let slice = data.get(off..off.checked_add(4)?)?;
    Some(u32::from_be_bytes([slice[0], slice[1], slice[2], slice[3]]))
}

fn read_u64_be(data: &[u8], off: usize) -> Option<u64> {
    let slice = data.get(off..off.checked_add(8)?)?;
    Some(u64::from_be_bytes([
        slice[0], slice[1], slice[2], slice[3], slice[4], slice[5], slice[6], slice[7],
    ]))
}

fn fourcc_to_string(bytes: [u8; 4]) -> String {
    bytes
        .iter()
        .map(|&b| {
            if (0x20..=0x7e).contains(&b) {
                b as char
            } else {
                '.'
            }
        })
        .collect()
}

// ============================================================================
// 1. ISOBMFF / MP4 / MOV / CMAF Parser
// ============================================================================

const MAX_ISOBMFF_DEPTH: usize = 32;
const MAX_ISOBMFF_BOXES: usize = 100_000;

#[derive(Default)]
struct IsobmffState {
    boxes_parsed: usize,
    has_ftyp: bool,
    has_styp: bool,
    has_moov: bool,
    major_brand: Option<String>,
    minor_version: Option<u32>,
    compatible_brands: Vec<String>,
    track_count: usize,
    moof_count: usize,
    stsd_codecs: Vec<String>,
    hvcc_entries: Vec<JsonVal>,
    avcc_entries: Vec<JsonVal>,
    dvcc_entries: Vec<JsonVal>,
    colr_entries: Vec<JsonVal>,
    mdcv_entries: Vec<JsonVal>,
    clli_entries: Vec<JsonVal>,
    tfdt_values: Vec<u64>,
    violations: Vec<String>,
}

fn is_container_box(box_type: &[u8; 4]) -> bool {
    matches!(
        box_type,
        b"moov"
            | b"trak"
            | b"mdia"
            | b"minf"
            | b"stbl"
            | b"dinf"
            | b"edts"
            | b"udta"
            | b"moof"
            | b"traf"
            | b"mvex"
            | b"tref"
            | b"sinf"
            | b"schi"
    )
}

fn is_visual_sample_entry(box_type: &[u8; 4]) -> bool {
    matches!(
        box_type,
        b"hvc1"
            | b"hev1"
            | b"avc1"
            | b"avc3"
            | b"dvh1"
            | b"dvhe"
            | b"av01"
            | b"apco"
            | b"apcs"
            | b"apcn"
            | b"apch"
            | b"ap4h"
            | b"ap4x"
            | b"mp4v"
            | b"vp09"
    )
}

fn chroma_format_name(idc: u8) -> &'static str {
    match idc {
        0 => "monochrome",
        1 => "4:2:0",
        2 => "4:2:2",
        3 => "4:4:4",
        _ => "unknown",
    }
}

fn parse_isobmff(data: &[u8]) -> ConformanceReport {
    let mut state = IsobmffState::default();

    if data.len() < 8 {
        state
            .violations
            .push("ISOBMFF input is smaller than minimum 8-byte box header".to_string());
    } else {
        parse_isobmff_range(data, 0, data.len(), 0, &mut state);
    }

    if !state.has_ftyp && !state.has_styp {
        state
            .violations
            .push("Missing required top-level `ftyp` (or CMAF `styp`) box".to_string());
    }
    if !state.has_moov && state.moof_count == 0 {
        state
            .violations
            .push("Missing `moov` box (and no CMAF `moof` fragments present)".to_string());
    }
    if state.has_ftyp && !state.has_moov && !state.has_styp {
        state
            .violations
            .push("Missing `moov` movie box in MP4/MOV file".to_string());
    }

    // Validate monotonic tfdt timestamps if multiple fragments exist.
    for win in state.tfdt_values.windows(2) {
        if win[1] < win[0] {
            state.violations.push(format!(
                "Non-monotonic `tfdt` baseMediaDecodeTime: {} followed by {}",
                win[0], win[1]
            ));
        }
    }

    let is_cmaf = state.moof_count > 0 || state.has_styp;
    let passed = state.violations.is_empty();

    let details = JsonVal::Obj(vec![
        ("size_bytes".to_string(), JsonVal::UInt(data.len() as u64)),
        (
            "boxes_parsed".to_string(),
            JsonVal::UInt(state.boxes_parsed as u64),
        ),
        ("has_ftyp".to_string(), JsonVal::Bool(state.has_ftyp)),
        ("has_styp".to_string(), JsonVal::Bool(state.has_styp)),
        ("has_moov".to_string(), JsonVal::Bool(state.has_moov)),
        ("is_fragmented_cmaf".to_string(), JsonVal::Bool(is_cmaf)),
        (
            "major_brand".to_string(),
            match state.major_brand {
                Some(b) => JsonVal::Str(b),
                None => JsonVal::Null,
            },
        ),
        (
            "minor_version".to_string(),
            match state.minor_version {
                Some(v) => JsonVal::UInt(v as u64),
                None => JsonVal::Null,
            },
        ),
        (
            "compatible_brands".to_string(),
            JsonVal::Arr(
                state
                    .compatible_brands
                    .into_iter()
                    .map(JsonVal::Str)
                    .collect(),
            ),
        ),
        (
            "track_count".to_string(),
            JsonVal::UInt(state.track_count as u64),
        ),
        (
            "moof_count".to_string(),
            JsonVal::UInt(state.moof_count as u64),
        ),
        (
            "stsd_codecs".to_string(),
            JsonVal::Arr(state.stsd_codecs.into_iter().map(JsonVal::Str).collect()),
        ),
        ("hvcC".to_string(), JsonVal::Arr(state.hvcc_entries)),
        ("avcC".to_string(), JsonVal::Arr(state.avcc_entries)),
        ("dvcC".to_string(), JsonVal::Arr(state.dvcc_entries)),
        ("colr".to_string(), JsonVal::Arr(state.colr_entries)),
        ("mdcv".to_string(), JsonVal::Arr(state.mdcv_entries)),
        ("clli".to_string(), JsonVal::Arr(state.clli_entries)),
        (
            "tfdt".to_string(),
            JsonVal::Arr(state.tfdt_values.into_iter().map(JsonVal::UInt).collect()),
        ),
    ]);

    ConformanceReport {
        passed,
        format: if is_cmaf {
            "cmaf".to_string()
        } else {
            "isobmff".to_string()
        },
        violations: state.violations,
        details,
    }
}

fn parse_isobmff_range(
    data: &[u8],
    start: usize,
    end: usize,
    depth: usize,
    state: &mut IsobmffState,
) {
    if depth > MAX_ISOBMFF_DEPTH {
        state.violations.push(format!(
            "ISOBMFF box nesting exceeded maximum depth ({})",
            MAX_ISOBMFF_DEPTH
        ));
        return;
    }

    let mut pos = start;
    while pos < end {
        if state.boxes_parsed >= MAX_ISOBMFF_BOXES {
            state.violations.push(format!(
                "ISOBMFF box count exceeded safety cap ({})",
                MAX_ISOBMFF_BOXES
            ));
            return;
        }

        let remaining = end.saturating_sub(pos);
        if remaining < 8 {
            state.violations.push(format!(
                "Truncated ISOBMFF box header at offset {} ({} trailing bytes)",
                pos, remaining
            ));
            return;
        }

        let size32 = match read_u32_be(data, pos) {
            Some(v) => v,
            None => return,
        };
        let type_slice = match data.get(pos + 4..pos + 8) {
            Some(s) => s,
            None => return,
        };
        let box_type: [u8; 4] = [type_slice[0], type_slice[1], type_slice[2], type_slice[3]];
        let type_name = fourcc_to_string(box_type);

        let (header_size, box_size_u64): (usize, u64) = if size32 == 1 {
            if remaining < 16 {
                state.violations.push(format!(
                    "Truncated 64-bit largesize header for box `{}` at offset {}",
                    type_name, pos
                ));
                return;
            }
            let large = match read_u64_be(data, pos + 8) {
                Some(v) => v,
                None => return,
            };
            (16, large)
        } else if size32 == 0 {
            (8, remaining as u64)
        } else {
            (8, size32 as u64)
        };

        // Extended UUID box adds 16 bytes to header.
        let header_size = if &box_type == b"uuid" {
            match header_size.checked_add(16) {
                Some(h) if (h as u64) <= box_size_u64 => h,
                _ => {
                    state.violations.push(format!(
                        "Malformed `uuid` box size {} at offset {}",
                        box_size_u64, pos
                    ));
                    return;
                }
            }
        } else {
            header_size
        };

        if box_size_u64 < header_size as u64 {
            state.violations.push(format!(
                "Invalid ISOBMFF box `{}` size {} < header size {} at offset {}",
                type_name, box_size_u64, header_size, pos
            ));
            return;
        }

        let box_size = match usize::try_from(box_size_u64) {
            Ok(v) => v,
            Err(_) => {
                state.violations.push(format!(
                    "Overflowing ISOBMFF box `{}` size {} at offset {}",
                    type_name, box_size_u64, pos
                ));
                return;
            }
        };

        let box_end = match pos.checked_add(box_size) {
            Some(e) if e <= end => e,
            _ => {
                state.violations.push(format!(
                    "ISOBMFF box `{}` at offset {} extends beyond parent boundary (size={}, remaining={})",
                    type_name, pos, box_size, remaining
                ));
                return;
            }
        };

        let payload_start = pos + header_size;
        let payload = &data[payload_start..box_end];
        state.boxes_parsed += 1;

        match &box_type {
            b"ftyp" => parse_ftyp(payload, false, state),
            b"styp" => parse_ftyp(payload, true, state),
            b"moov" => {
                state.has_moov = true;
                parse_isobmff_range(data, payload_start, box_end, depth + 1, state);
            }
            b"trak" => {
                state.track_count += 1;
                parse_isobmff_range(data, payload_start, box_end, depth + 1, state);
            }
            b"moof" => {
                state.moof_count += 1;
                parse_isobmff_range(data, payload_start, box_end, depth + 1, state);
            }
            b"meta" => {
                // ISO 14496-12 `meta` is a FullBox (4-byte version/flags before children) unless QuickTime non-fullbox.
                if payload.len() >= 4 {
                    parse_isobmff_range(data, payload_start + 4, box_end, depth + 1, state);
                }
            }
            b"stsd" => parse_stsd(data, payload_start, box_end, depth + 1, state),
            b"hvcC" => parse_hvcc(payload, state),
            b"avcC" => parse_avcc(payload, state),
            b"dvcC" | b"dvwC" => parse_dvcc(payload, state),
            b"colr" => parse_colr(payload, state),
            b"mdcv" => parse_mdcv(payload, state),
            b"clli" => parse_clli(payload, state),
            b"tfdt" => parse_tfdt(payload, state),
            _ if is_container_box(&box_type) => {
                parse_isobmff_range(data, payload_start, box_end, depth + 1, state);
            }
            _ => {}
        }

        pos = box_end;
    }
}

fn parse_ftyp(payload: &[u8], is_styp: bool, state: &mut IsobmffState) {
    if is_styp {
        state.has_styp = true;
    } else {
        state.has_ftyp = true;
    }
    if payload.len() < 8 {
        state.violations.push(format!(
            "`{}` box payload too short ({} bytes, need >= 8)",
            if is_styp { "styp" } else { "ftyp" },
            payload.len()
        ));
        return;
    }
    let major = fourcc_to_string([payload[0], payload[1], payload[2], payload[3]]);
    let minor = read_u32_be(payload, 4).unwrap_or(0);
    if !is_styp || state.major_brand.is_none() {
        state.major_brand = Some(major);
        state.minor_version = Some(minor);
    }

    let mut off = 8;
    while off + 4 <= payload.len() {
        let brand = fourcc_to_string([
            payload[off],
            payload[off + 1],
            payload[off + 2],
            payload[off + 3],
        ]);
        if !state.compatible_brands.contains(&brand) {
            state.compatible_brands.push(brand);
        }
        off += 4;
    }
}

fn parse_stsd(
    data: &[u8],
    payload_start: usize,
    payload_end: usize,
    depth: usize,
    state: &mut IsobmffState,
) {
    let payload_len = payload_end.saturating_sub(payload_start);
    if payload_len < 8 {
        state.violations.push(format!(
            "`stsd` FullBox payload too short ({} bytes, need >= 8)",
            payload_len
        ));
        return;
    }
    let entry_count = read_u32_be(data, payload_start + 4).unwrap_or(0);
    let mut pos = payload_start + 8;

    for _ in 0..entry_count {
        if pos >= payload_end {
            state
                .violations
                .push("`stsd` entry_count exceeds box payload bounds".to_string());
            break;
        }
        let rem = payload_end - pos;
        if rem < 8 {
            state
                .violations
                .push("Truncated sample entry inside `stsd`".to_string());
            break;
        }
        let entry_size = read_u32_be(data, pos).unwrap_or(0) as usize;
        let codec_bytes = [data[pos + 4], data[pos + 5], data[pos + 6], data[pos + 7]];
        let codec_name = fourcc_to_string(codec_bytes);

        if entry_size < 8 || pos.checked_add(entry_size).map_or(true, |e| e > payload_end) {
            state.violations.push(format!(
                "Invalid `stsd` sample entry `{}` size {} at offset {}",
                codec_name, entry_size, pos
            ));
            break;
        }

        if !state.stsd_codecs.contains(&codec_name) {
            state.stsd_codecs.push(codec_name);
        }

        let entry_end = pos + entry_size;
        // VisualSampleEntry fixed fields = 8-byte box header + 78-byte visual header = 86 bytes total.
        if is_visual_sample_entry(&codec_bytes) && entry_size > 86 {
            parse_isobmff_range(data, pos + 86, entry_end, depth + 1, state);
        }
        pos = entry_end;
    }
}

fn parse_hvcc(payload: &[u8], state: &mut IsobmffState) {
    // ISO/IEC 14496-15 HEVCDecoderConfigurationRecord is at least 23 bytes.
    if payload.len() < 23 {
        state.violations.push(format!(
            "Malformed `hvcC` box: {} bytes (minimum 23 bytes required)",
            payload.len()
        ));
        return;
    }
    let config_version = payload[0];
    let profile_byte = payload[1];
    let general_profile_space = (profile_byte >> 6) & 0x03;
    let general_tier_flag = (profile_byte >> 5) & 0x01;
    let general_profile_idc = profile_byte & 0x1F;
    let general_level_idc = payload[12];
    let chroma_format_idc = payload[16] & 0x03;
    let bit_depth_luma = (payload[17] & 0x07) + 8;
    let bit_depth_chroma = (payload[18] & 0x07) + 8;
    let num_of_arrays = payload[22];

    if config_version != 1 {
        state.violations.push(format!(
            "`hvcC` unexpected configurationVersion={} (expected 1)",
            config_version
        ));
    }

    state.hvcc_entries.push(JsonVal::Obj(vec![
        (
            "configuration_version".to_string(),
            JsonVal::UInt(config_version as u64),
        ),
        (
            "general_profile_space".to_string(),
            JsonVal::UInt(general_profile_space as u64),
        ),
        (
            "general_tier_flag".to_string(),
            JsonVal::UInt(general_tier_flag as u64),
        ),
        (
            "general_profile_idc".to_string(),
            JsonVal::UInt(general_profile_idc as u64),
        ),
        (
            "general_level_idc".to_string(),
            JsonVal::UInt(general_level_idc as u64),
        ),
        (
            "chroma_format_idc".to_string(),
            JsonVal::UInt(chroma_format_idc as u64),
        ),
        (
            "chroma_subsampling".to_string(),
            JsonVal::Str(chroma_format_name(chroma_format_idc).to_string()),
        ),
        (
            "bit_depth_luma".to_string(),
            JsonVal::UInt(bit_depth_luma as u64),
        ),
        (
            "bit_depth_chroma".to_string(),
            JsonVal::UInt(bit_depth_chroma as u64),
        ),
        (
            "num_of_arrays".to_string(),
            JsonVal::UInt(num_of_arrays as u64),
        ),
    ]));
}

fn parse_avcc(payload: &[u8], state: &mut IsobmffState) {
    // ISO/IEC 14496-15 AVCDecoderConfigurationRecord minimum header is 7 bytes.
    if payload.len() < 7 {
        state.violations.push(format!(
            "Malformed `avcC` box: {} bytes (minimum 7 bytes required)",
            payload.len()
        ));
        return;
    }
    let config_version = payload[0];
    let profile_idc = payload[1];
    let profile_compat = payload[2];
    let level_idc = payload[3];
    let nal_length_size = (payload[4] & 0x03) + 1;
    let sps_count = payload[5] & 0x1F;

    if config_version != 1 {
        state.violations.push(format!(
            "`avcC` unexpected configurationVersion={} (expected 1)",
            config_version
        ));
    }

    state.avcc_entries.push(JsonVal::Obj(vec![
        (
            "configuration_version".to_string(),
            JsonVal::UInt(config_version as u64),
        ),
        (
            "avc_profile_indication".to_string(),
            JsonVal::UInt(profile_idc as u64),
        ),
        (
            "profile_compatibility".to_string(),
            JsonVal::UInt(profile_compat as u64),
        ),
        (
            "avc_level_indication".to_string(),
            JsonVal::UInt(level_idc as u64),
        ),
        (
            "nal_length_size".to_string(),
            JsonVal::UInt(nal_length_size as u64),
        ),
        ("sps_count".to_string(), JsonVal::UInt(sps_count as u64)),
    ]));
}

fn parse_dvcc(payload: &[u8], state: &mut IsobmffState) {
    // Dolby Vision Configuration Box (`dvcC` / `dvwC`) is 24 bytes (first 5 bytes carry version/profile/level/flags).
    if payload.len() < 5 {
        state.violations.push(format!(
            "Malformed `dvcC` box: {} bytes (minimum 5 bytes required)",
            payload.len()
        ));
        return;
    }
    let dv_version_major = payload[0];
    let dv_version_minor = payload[1];
    let b2 = payload[2];
    let b3 = payload[3];
    let b4 = payload[4];
    let dv_profile = (b2 >> 1) & 0x7F;
    let dv_level = ((b2 & 0x01) << 5) | ((b3 >> 3) & 0x1F);
    let rpu_present = ((b3 >> 2) & 0x01) != 0;
    let el_present = ((b3 >> 1) & 0x01) != 0;
    let bl_present = (b3 & 0x01) != 0;
    let bl_signal_compat_id = (b4 >> 4) & 0x0F;

    state.dvcc_entries.push(JsonVal::Obj(vec![
        (
            "dv_version_major".to_string(),
            JsonVal::UInt(dv_version_major as u64),
        ),
        (
            "dv_version_minor".to_string(),
            JsonVal::UInt(dv_version_minor as u64),
        ),
        ("dv_profile".to_string(), JsonVal::UInt(dv_profile as u64)),
        ("dv_level".to_string(), JsonVal::UInt(dv_level as u64)),
        ("rpu_present".to_string(), JsonVal::Bool(rpu_present)),
        ("el_present".to_string(), JsonVal::Bool(el_present)),
        ("bl_present".to_string(), JsonVal::Bool(bl_present)),
        (
            "bl_signal_compat_id".to_string(),
            JsonVal::UInt(bl_signal_compat_id as u64),
        ),
    ]));
}

fn parse_colr(payload: &[u8], state: &mut IsobmffState) {
    if payload.len() < 4 {
        state.violations.push(format!(
            "Malformed `colr` box: {} bytes (minimum 4 bytes required)",
            payload.len()
        ));
        return;
    }
    let colr_type = fourcc_to_string([payload[0], payload[1], payload[2], payload[3]]);
    if colr_type == "nclx" || colr_type == "nclc" {
        if payload.len() < 10 {
            state.violations.push(format!(
                "Malformed `colr` ({}) box: {} bytes (minimum 10 bytes required)",
                colr_type,
                payload.len()
            ));
            return;
        }
        let primaries = read_u16_be(payload, 4).unwrap_or(0);
        let transfer = read_u16_be(payload, 6).unwrap_or(0);
        let matrix = read_u16_be(payload, 8).unwrap_or(0);
        let full_range = payload.get(10).map(|b| (b & 0x80) != 0).unwrap_or(false);

        state.colr_entries.push(JsonVal::Obj(vec![
            ("color_type".to_string(), JsonVal::Str(colr_type)),
            (
                "colour_primaries".to_string(),
                JsonVal::UInt(primaries as u64),
            ),
            (
                "transfer_characteristics".to_string(),
                JsonVal::UInt(transfer as u64),
            ),
            (
                "matrix_coefficients".to_string(),
                JsonVal::UInt(matrix as u64),
            ),
            ("full_range_flag".to_string(), JsonVal::Bool(full_range)),
        ]));
    } else {
        state.colr_entries.push(JsonVal::Obj(vec![
            ("color_type".to_string(), JsonVal::Str(colr_type)),
            (
                "payload_bytes".to_string(),
                JsonVal::UInt(payload.len() as u64),
            ),
        ]));
    }
}

fn parse_mdcv(payload: &[u8], state: &mut IsobmffState) {
    // SMPTE ST 2086 MasteringDisplayColourVolumeBox: 24 bytes (6x u16 primaries + 2x u16 white + 2x u32 luminance).
    if payload.len() < 24 {
        state.violations.push(format!(
            "Malformed `mdcv` box: {} bytes (minimum 24 bytes required)",
            payload.len()
        ));
        return;
    }
    let max_lum = read_u32_be(payload, 16).unwrap_or(0);
    let min_lum = read_u32_be(payload, 20).unwrap_or(0);
    let wp_x = read_u16_be(payload, 12).unwrap_or(0);
    let wp_y = read_u16_be(payload, 14).unwrap_or(0);

    state.mdcv_entries.push(JsonVal::Obj(vec![
        ("white_point_x".to_string(), JsonVal::UInt(wp_x as u64)),
        ("white_point_y".to_string(), JsonVal::UInt(wp_y as u64)),
        (
            "max_display_mastering_luminance".to_string(),
            JsonVal::UInt(max_lum as u64),
        ),
        (
            "min_display_mastering_luminance".to_string(),
            JsonVal::UInt(min_lum as u64),
        ),
    ]));
}

fn parse_clli(payload: &[u8], state: &mut IsobmffState) {
    // ContentLightLevelBox: 4 bytes (u16 maxCLL + u16 maxFALL).
    if payload.len() < 4 {
        state.violations.push(format!(
            "Malformed `clli` box: {} bytes (minimum 4 bytes required)",
            payload.len()
        ));
        return;
    }
    let max_cll = read_u16_be(payload, 0).unwrap_or(0);
    let max_fall = read_u16_be(payload, 2).unwrap_or(0);
    state.clli_entries.push(JsonVal::Obj(vec![
        (
            "max_content_light_level".to_string(),
            JsonVal::UInt(max_cll as u64),
        ),
        (
            "max_pic_average_light_level".to_string(),
            JsonVal::UInt(max_fall as u64),
        ),
    ]));
}

fn parse_tfdt(payload: &[u8], state: &mut IsobmffState) {
    if payload.len() < 8 {
        state.violations.push(format!(
            "Malformed `tfdt` FullBox: {} bytes (minimum 8 bytes required)",
            payload.len()
        ));
        return;
    }
    let version = payload[0];
    let decode_time = if version == 1 {
        if payload.len() < 12 {
            state.violations.push(format!(
                "Malformed `tfdt` v1 box: {} bytes (minimum 12 bytes required)",
                payload.len()
            ));
            return;
        }
        read_u64_be(payload, 4).unwrap_or(0)
    } else {
        read_u32_be(payload, 4).unwrap_or(0) as u64
    };
    state.tfdt_values.push(decode_time);
}

// ============================================================================
// 2. MPEG-TS 188-Byte Packet Parser
// ============================================================================

const TS_PACKET_SIZE: usize = 188;
const TS_SYNC_BYTE: u8 = 0x47;

fn parse_mpeg_ts(data: &[u8]) -> ConformanceReport {
    let mut violations: Vec<String> = Vec::new();
    let total_packets = data.len() / TS_PACKET_SIZE;
    let trailing_bytes = data.len() % TS_PACKET_SIZE;

    if data.is_empty() {
        violations.push("Empty MPEG-TS input".to_string());
    } else if trailing_bytes != 0 {
        violations.push(format!(
            "MPEG-TS length {} is not a multiple of 188 bytes ({} trailing bytes)",
            data.len(),
            trailing_bytes
        ));
    }

    let mut sync_errors: usize = 0;
    let mut continuity_errors: usize = 0;
    let mut pat_packets: usize = 0;
    let mut pmt_packets: usize = 0;
    let mut pmt_pids: BTreeSet<u16> = BTreeSet::new();
    let mut elementary_streams: BTreeMap<u16, u8> = BTreeMap::new();
    let mut last_cc: BTreeMap<u16, u8> = BTreeMap::new();
    let mut unique_pids: BTreeSet<u16> = BTreeSet::new();

    for pkt_idx in 0..total_packets {
        let off = pkt_idx * TS_PACKET_SIZE;
        let pkt = &data[off..off + TS_PACKET_SIZE];

        if pkt[0] != TS_SYNC_BYTE {
            sync_errors += 1;
            if sync_errors <= 5 {
                violations.push(format!(
                    "MPEG-TS sync byte mismatch at packet {} (offset {}): expected 0x47, found 0x{:02X}",
                    pkt_idx, off, pkt[0]
                ));
            }
            continue;
        }

        let pusi = (pkt[1] & 0x40) != 0;
        let pid = (((pkt[1] & 0x1F) as u16) << 8) | (pkt[2] as u16);
        let afc = (pkt[3] >> 4) & 0x03;
        let cc = pkt[3] & 0x0F;

        unique_pids.insert(pid);

        let has_adaptation = (afc & 0x02) != 0;
        let has_payload = (afc & 0x01) != 0;

        let mut payload_off = 4usize;
        let mut discontinuity = false;

        if has_adaptation {
            let af_len = pkt[4] as usize;
            if af_len > 0 && payload_off + 1 < TS_PACKET_SIZE {
                discontinuity = (pkt[5] & 0x80) != 0;
            }
            payload_off = payload_off.saturating_add(1).saturating_add(af_len);
            if payload_off > TS_PACKET_SIZE {
                violations.push(format!(
                    "Invalid adaptation field length {} in packet {} (PID 0x{:04X})",
                    af_len, pkt_idx, pid
                ));
                continue;
            }
        }

        // Continuity counter check for non-null PIDs carrying payload.
        if pid != 0x1FFF && has_payload {
            if let Some(&prev_cc) = last_cc.get(&pid) {
                let expected = (prev_cc + 1) & 0x0F;
                if !discontinuity && cc != expected {
                    continuity_errors += 1;
                    if continuity_errors <= 10 {
                        violations.push(format!(
                            "Continuity counter jump on PID 0x{:04X} at packet {}: expected {}, got {}",
                            pid, pkt_idx, expected, cc
                        ));
                    }
                }
            }
            last_cc.insert(pid, cc);
        }

        if has_payload && payload_off < TS_PACKET_SIZE {
            let payload = &pkt[payload_off..];
            if pid == 0x0000 && pusi {
                pat_packets += 1;
                parse_ts_pat(payload, &mut pmt_pids, &mut violations);
            } else if pmt_pids.contains(&pid) && pusi {
                pmt_packets += 1;
                parse_ts_pmt(payload, &mut elementary_streams, &mut violations);
            }
        }
    }

    if total_packets > 0 && pat_packets == 0 {
        violations.push("Missing MPEG-TS PAT (PID 0x0000)".to_string());
    }
    if total_packets > 0 && !pmt_pids.is_empty() && pmt_packets == 0 {
        violations.push("PAT declared PMT PID(s), but no PMT section was found".to_string());
    }

    let streams_json: Vec<JsonVal> = elementary_streams
        .iter()
        .map(|(&es_pid, &stream_type)| {
            JsonVal::Obj(vec![
                ("pid".to_string(), JsonVal::UInt(es_pid as u64)),
                (
                    "stream_type".to_string(),
                    JsonVal::UInt(stream_type as u64),
                ),
            ])
        })
        .collect();

    let passed = violations.is_empty();
    let details = JsonVal::Obj(vec![
        (
            "packets_parsed".to_string(),
            JsonVal::UInt(total_packets as u64),
        ),
        (
            "trailing_bytes".to_string(),
            JsonVal::UInt(trailing_bytes as u64),
        ),
        (
            "sync_errors".to_string(),
            JsonVal::UInt(sync_errors as u64),
        ),
        (
            "continuity_errors".to_string(),
            JsonVal::UInt(continuity_errors as u64),
        ),
        (
            "pat_packets".to_string(),
            JsonVal::UInt(pat_packets as u64),
        ),
        (
            "pmt_packets".to_string(),
            JsonVal::UInt(pmt_packets as u64),
        ),
        (
            "pmt_pids".to_string(),
            JsonVal::Arr(pmt_pids.into_iter().map(|p| JsonVal::UInt(p as u64)).collect()),
        ),
        (
            "unique_pid_count".to_string(),
            JsonVal::UInt(unique_pids.len() as u64),
        ),
        ("elementary_streams".to_string(), JsonVal::Arr(streams_json)),
    ]);

    ConformanceReport {
        passed,
        format: "mpeg-ts".to_string(),
        violations,
        details,
    }
}

fn parse_ts_pat(payload: &[u8], pmt_pids: &mut BTreeSet<u16>, violations: &mut Vec<String>) {
    if payload.is_empty() {
        return;
    }
    let pointer = payload[0] as usize;
    let sec_start = 1usize.saturating_add(pointer);
    let sec = match payload.get(sec_start..) {
        Some(s) if s.len() >= 8 => s,
        _ => {
            violations.push("Truncated MPEG-TS PAT section".to_string());
            return;
        }
    };

    let table_id = sec[0];
    if table_id != 0x00 {
        violations.push(format!(
            "PAT packet had unexpected table_id 0x{:02X} (expected 0x00)",
            table_id
        ));
        return;
    }
    let section_len = ((((sec[1] & 0x0F) as usize) << 8) | (sec[2] as usize)).min(sec.len().saturating_sub(3));
    let total_end = 3usize.saturating_add(section_len);
    // Program loop starts at offset 8 and ends 4 bytes before section end (CRC32).
    if total_end < 12 || total_end > sec.len() {
        return;
    }
    let loop_end = total_end - 4;
    let mut off = 8;
    while off + 4 <= loop_end {
        let program_num = u16::from_be_bytes([sec[off], sec[off + 1]]);
        let pid = (((sec[off + 2] & 0x1F) as u16) << 8) | (sec[off + 3] as u16);
        if program_num != 0 {
            pmt_pids.insert(pid);
        }
        off += 4;
    }
}

fn parse_ts_pmt(
    payload: &[u8],
    elementary_streams: &mut BTreeMap<u16, u8>,
    violations: &mut Vec<String>,
) {
    if payload.is_empty() {
        return;
    }
    let pointer = payload[0] as usize;
    let sec_start = 1usize.saturating_add(pointer);
    let sec = match payload.get(sec_start..) {
        Some(s) if s.len() >= 12 => s,
        _ => {
            violations.push("Truncated MPEG-TS PMT section".to_string());
            return;
        }
    };

    let table_id = sec[0];
    if table_id != 0x02 {
        violations.push(format!(
            "PMT packet had unexpected table_id 0x{:02X} (expected 0x02)",
            table_id
        ));
        return;
    }

    let section_len = ((((sec[1] & 0x0F) as usize) << 8) | (sec[2] as usize)).min(sec.len().saturating_sub(3));
    let total_end = 3usize.saturating_add(section_len);
    if total_end < 16 || total_end > sec.len() {
        return;
    }
    let prog_info_len = (((sec[10] & 0x0F) as usize) << 8) | (sec[11] as usize);
    let mut off = 12usize.saturating_add(prog_info_len);
    let loop_end = total_end - 4;

    while off + 5 <= loop_end {
        let stream_type = sec[off];
        let es_pid = (((sec[off + 1] & 0x1F) as u16) << 8) | (sec[off + 2] as u16);
        let es_info_len = (((sec[off + 3] & 0x0F) as usize) << 8) | (sec[off + 4] as usize);
        elementary_streams.insert(es_pid, stream_type);
        off = off.saturating_add(5).saturating_add(es_info_len);
    }
}

// ============================================================================
// 3. HLS `.m3u8` & LL-HLS Playlist Parser
// ============================================================================

struct LlHlsPartEntry {
    line: usize,
    uri: Option<String>,
    duration: Option<f64>,
    independent: bool,
}

fn starts_with_valid_cmaf_part_box(data: &[u8]) -> bool {
    if data.len() < 8 {
        return false;
    }
    let size32 = match read_u32_be(data, 0) {
        Some(v) => v,
        None => return false,
    };
    let fourcc = &data[4..8];
    if fourcc != b"styp" && fourcc != b"moof" {
        return false;
    }
    if size32 == 0 {
        true
    } else if size32 == 1 {
        match read_u64_be(data, 8) {
            Some(large) => large >= 16 && large <= data.len() as u64,
            None => false,
        }
    } else {
        size32 >= 8 && (size32 as usize) <= data.len()
    }
}

fn parse_hls(data: &[u8]) -> ConformanceReport {
    parse_hls_with_base_dir(data, None)
}

fn parse_hls_with_base_dir(data: &[u8], base_dir: Option<&Path>) -> ConformanceReport {
    let mut violations: Vec<String> = Vec::new();
    let text = match std::str::from_utf8(data) {
        Ok(s) => s,
        Err(_) => {
            violations.push("HLS playlist is not valid UTF-8".to_string());
            return ConformanceReport {
                passed: false,
                format: "hls".to_string(),
                violations,
                details: JsonVal::Obj(vec![]),
            };
        }
    };

    let trimmed_bom = text.strip_prefix('\u{feff}').unwrap_or(text);
    let lines: Vec<&str> = trimmed_bom
        .lines()
        .map(|l| l.trim_end_matches('\r').trim())
        .collect();

    let first_non_empty = lines.iter().copied().find(|l| !l.is_empty());
    let has_extm3u = first_non_empty == Some("#EXTM3U");
    if !has_extm3u {
        violations.push("Missing required `#EXTM3U` header on first line".to_string());
    }

    let mut version: Option<u32> = None;
    let mut target_duration: Option<u64> = None;
    let mut has_endlist = false;
    let mut playlist_type: Option<String> = None;
    let mut segment_count: usize = 0;
    let mut max_extinf_duration: f64 = 0.0;
    let mut stream_inf_variants: Vec<JsonVal> = Vec::new();
    let mut pending_stream_inf = false;
    let mut pending_extinf = false;

    // LL-HLS state
    let mut has_part_inf = false;
    let mut part_target: Option<f64> = None;
    let mut has_server_control = false;
    let mut part_hold_back: Option<f64> = None;
    let mut ll_hls_parts: Vec<LlHlsPartEntry> = Vec::new();

    for (line_idx, &line) in lines.iter().enumerate() {
        if line.is_empty() {
            continue;
        }

        if let Some(val) = line.strip_prefix("#EXT-X-VERSION:") {
            match val.trim().parse::<u32>() {
                Ok(v) if v >= 1 => version = Some(v),
                _ => violations.push(format!(
                    "Invalid `#EXT-X-VERSION` value `{}` on line {}",
                    val,
                    line_idx + 1
                )),
            }
        } else if let Some(val) = line.strip_prefix("#EXT-X-TARGETDURATION:") {
            match val.trim().parse::<u64>() {
                Ok(v) if v >= 1 => target_duration = Some(v),
                _ => violations.push(format!(
                    "Invalid `#EXT-X-TARGETDURATION` value `{}` on line {}",
                    val,
                    line_idx + 1
                )),
            }
        } else if let Some(attrs) = line.strip_prefix("#EXT-X-PART-INF:") {
            has_part_inf = true;
            let parsed = parse_hls_attribute_list(attrs);
            match parsed.get("PART-TARGET").and_then(|v| v.parse::<f64>().ok()) {
                Some(pt) if pt.is_finite() && pt > 0.0 => part_target = Some(pt),
                _ => violations.push(format!(
                    "`#EXT-X-PART-INF` on line {} missing or non-positive PART-TARGET attribute",
                    line_idx + 1
                )),
            }
        } else if let Some(attrs) = line.strip_prefix("#EXT-X-SERVER-CONTROL:") {
            has_server_control = true;
            let parsed = parse_hls_attribute_list(attrs);
            if let Some(raw_phb) = parsed.get("PART-HOLD-BACK") {
                match raw_phb.parse::<f64>() {
                    Ok(phb) if phb.is_finite() && phb > 0.0 => part_hold_back = Some(phb),
                    _ => violations.push(format!(
                        "`#EXT-X-SERVER-CONTROL` on line {} has invalid PART-HOLD-BACK `{}`",
                        line_idx + 1,
                        raw_phb
                    )),
                }
            }
        } else if let Some(attrs) = line.strip_prefix("#EXT-X-PART:") {
            let parsed = parse_hls_attribute_list(attrs);
            let uri = parsed
                .get("URI")
                .map(|u| u.trim().to_string())
                .filter(|u| !u.is_empty());
            if uri.is_none() {
                violations.push(format!(
                    "`#EXT-X-PART` on line {} missing required URI attribute",
                    line_idx + 1
                ));
            }
            let duration = match parsed.get("DURATION").and_then(|v| v.parse::<f64>().ok()) {
                Some(d) if d.is_finite() && d > 0.0 => Some(d),
                _ => {
                    violations.push(format!(
                        "`#EXT-X-PART` on line {} missing or non-positive DURATION attribute",
                        line_idx + 1
                    ));
                    None
                }
            };
            let independent = parsed
                .get("INDEPENDENT")
                .map(|v| v.eq_ignore_ascii_case("YES"))
                .unwrap_or(false);
            ll_hls_parts.push(LlHlsPartEntry {
                line: line_idx + 1,
                uri,
                duration,
                independent,
            });
        } else if line == "#EXT-X-ENDLIST" {
            has_endlist = true;
        } else if let Some(val) = line.strip_prefix("#EXT-X-PLAYLIST-TYPE:") {
            playlist_type = Some(val.trim().to_string());
        } else if let Some(rest) = line.strip_prefix("#EXTINF:") {
            let dur_str = rest.split(',').next().unwrap_or("").trim();
            match dur_str.parse::<f64>() {
                Ok(d) if d.is_finite() && d >= 0.0 => {
                    if d > max_extinf_duration {
                        max_extinf_duration = d;
                    }
                    pending_extinf = true;
                }
                _ => violations.push(format!(
                    "Invalid `#EXTINF` duration `{}` on line {}",
                    dur_str,
                    line_idx + 1
                )),
            }
        } else if let Some(attrs) = line.strip_prefix("#EXT-X-STREAM-INF:") {
            if pending_stream_inf {
                violations.push(format!(
                    "`#EXT-X-STREAM-INF` on line {} appeared before previous variant URI",
                    line_idx + 1
                ));
            }
            let parsed = parse_hls_attribute_list(attrs);
            if !parsed.contains_key("BANDWIDTH") {
                violations.push(format!(
                    "`#EXT-X-STREAM-INF` on line {} missing required BANDWIDTH attribute",
                    line_idx + 1
                ));
            }
            let mut obj_entries: Vec<(String, JsonVal)> = parsed
                .into_iter()
                .map(|(k, v)| (k, JsonVal::Str(v)))
                .collect();
            obj_entries.push(("line".to_string(), JsonVal::UInt((line_idx + 1) as u64)));
            stream_inf_variants.push(JsonVal::Obj(obj_entries));
            pending_stream_inf = true;
        } else if !line.starts_with('#') {
            if pending_stream_inf {
                pending_stream_inf = false;
            } else if pending_extinf {
                segment_count += 1;
                pending_extinf = false;
            }
        }
    }

    if pending_stream_inf {
        violations.push("Trailing `#EXT-X-STREAM-INF` missing variant URI line".to_string());
    }
    if pending_extinf {
        violations.push("Trailing `#EXTINF` missing media segment URI line".to_string());
    }

    let is_master = !stream_inf_variants.is_empty();
    if !is_master {
        match target_duration {
            None => violations
                .push("Media playlist missing required `#EXT-X-TARGETDURATION`".to_string()),
            Some(td) => {
                // RFC 8216 §4.3.3.1: rounded nearest integer of EXTINF duration must be <= TARGETDURATION.
                if max_extinf_duration > (td as f64) + 0.5 {
                    violations.push(format!(
                        "`#EXTINF` duration {:.3}s exceeds `#EXT-X-TARGETDURATION` {}s",
                        max_extinf_duration, td
                    ));
                }
            }
        }
        if playlist_type.as_deref() == Some("VOD") && !has_endlist {
            violations.push("VOD media playlist missing `#EXT-X-ENDLIST`".to_string());
        }
    }

    let is_ll_hls = has_part_inf || has_server_control || !ll_hls_parts.is_empty();
    let part_count = ll_hls_parts.len();
    let independent_part_count = ll_hls_parts.iter().filter(|p| p.independent).count();

    if is_ll_hls {
        if !has_part_inf {
            violations.push(
                "LL-HLS playlist missing required `#EXT-X-PART-INF:PART-TARGET=...`".to_string(),
            );
        }
        if !has_server_control {
            violations.push(
                "LL-HLS playlist missing required `#EXT-X-SERVER-CONTROL` with `PART-HOLD-BACK`"
                    .to_string(),
            );
        } else {
            match part_hold_back {
                None => violations.push(
                    "LL-HLS `#EXT-X-SERVER-CONTROL` missing required `PART-HOLD-BACK` attribute"
                        .to_string(),
                ),
                Some(phb) => {
                    if let Some(pt) = part_target {
                        let min_hold_back = 2.0 * pt;
                        if phb + 1e-6 < min_hold_back {
                            violations.push(format!(
                                "LL-HLS `PART-HOLD-BACK` ({:.3}s) must be >= 2.0 * `PART-TARGET` ({:.3}s)",
                                phb, min_hold_back
                            ));
                        }
                    }
                }
            }
        }

        for part in &ll_hls_parts {
            if let (Some(dur), Some(pt)) = (part.duration, part_target) {
                let max_part_dur = pt * 1.15;
                if dur > max_part_dur + 1e-6 {
                    violations.push(format!(
                        "LL-HLS `#EXT-X-PART` on line {} DURATION {:.3}s exceeds `PART-TARGET * 1.15` ({:.3}s)",
                        part.line, dur, max_part_dur
                    ));
                }
            }

            if let (Some(dir), Some(uri)) = (base_dir, part.uri.as_deref()) {
                let rel = uri.split('?').next().unwrap_or(uri);
                let resolved_dir = if dir.as_os_str().is_empty() {
                    Path::new(".")
                } else {
                    dir
                };
                let part_path = resolved_dir.join(rel);
                match fs::read(&part_path) {
                    Err(_) => violations.push(format!(
                        "LL-HLS `#EXT-X-PART` on line {} references missing part file `{}`",
                        part.line, uri
                    )),
                    Ok(bytes) if bytes.is_empty() => violations.push(format!(
                        "LL-HLS `#EXT-X-PART` on line {} part file `{}` is empty",
                        part.line, uri
                    )),
                    Ok(bytes) => {
                        if !starts_with_valid_cmaf_part_box(&bytes) {
                            violations.push(format!(
                                "LL-HLS `#EXT-X-PART` on line {} part file `{}` does not start with a valid CMAF ISOBMFF `styp` or `moof` box",
                                part.line, uri
                            ));
                        }
                    }
                }
            }
        }
    }

    let passed = violations.is_empty();
    let details = JsonVal::Obj(vec![
        ("has_extm3u".to_string(), JsonVal::Bool(has_extm3u)),
        (
            "playlist_kind".to_string(),
            JsonVal::Str(if is_master { "master" } else { "media" }.to_string()),
        ),
        (
            "version".to_string(),
            match version {
                Some(v) => JsonVal::UInt(v as u64),
                None => JsonVal::Null,
            },
        ),
        (
            "target_duration".to_string(),
            match target_duration {
                Some(v) => JsonVal::UInt(v),
                None => JsonVal::Null,
            },
        ),
        ("has_endlist".to_string(), JsonVal::Bool(has_endlist)),
        (
            "segment_count".to_string(),
            JsonVal::UInt(segment_count as u64),
        ),
        (
            "max_extinf_duration".to_string(),
            JsonVal::Float(max_extinf_duration),
        ),
        ("is_ll_hls".to_string(), JsonVal::Bool(is_ll_hls)),
        ("part_count".to_string(), JsonVal::UInt(part_count as u64)),
        (
            "independent_part_count".to_string(),
            JsonVal::UInt(independent_part_count as u64),
        ),
        (
            "part_target".to_string(),
            match part_target {
                Some(v) => JsonVal::Float(v),
                None => JsonVal::Null,
            },
        ),
        (
            "part_hold_back".to_string(),
            match part_hold_back {
                Some(v) => JsonVal::Float(v),
                None => JsonVal::Null,
            },
        ),
        (
            "stream_inf_count".to_string(),
            JsonVal::UInt(stream_inf_variants.len() as u64),
        ),
        (
            "stream_inf_variants".to_string(),
            JsonVal::Arr(stream_inf_variants),
        ),
    ]);

    ConformanceReport {
        passed,
        format: "hls".to_string(),
        violations,
        details,
    }
}

fn parse_hls_attribute_list(input: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    let bytes = input.as_bytes();
    let mut i = 0usize;

    while i < bytes.len() {
        while i < bytes.len() && (bytes[i] == b',' || bytes[i] == b' ') {
            i += 1;
        }
        let key_start = i;
        while i < bytes.len() && bytes[i] != b'=' && bytes[i] != b',' {
            i += 1;
        }
        if i >= bytes.len() || bytes[i] != b'=' {
            break;
        }
        let key = input[key_start..i].trim().to_string();
        i += 1; // skip '='

        let val = if i < bytes.len() && bytes[i] == b'"' {
            i += 1;
            let val_start = i;
            while i < bytes.len() && bytes[i] != b'"' {
                i += 1;
            }
            let s = input[val_start..i].to_string();
            if i < bytes.len() && bytes[i] == b'"' {
                i += 1;
            }
            s
        } else {
            let val_start = i;
            while i < bytes.len() && bytes[i] != b',' {
                i += 1;
            }
            input[val_start..i].trim().to_string()
        };

        if !key.is_empty() {
            map.insert(key, val);
        }
    }
    map
}

// ============================================================================
// Auto-Detection & CLI Entrypoint
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InputFormat {
    Isobmff,
    MpegTs,
    Hls,
}

fn detect_format(path: &Path, data: &[u8]) -> InputFormat {
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        match ext.to_ascii_lowercase().as_str() {
            "m3u8" | "m3u" => return InputFormat::Hls,
            "ts" | "m2ts" => return InputFormat::MpegTs,
            "mp4" | "mov" | "m4v" | "m4s" | "m4a" | "cmfv" | "cmfa" => return InputFormat::Isobmff,
            _ => {}
        }
    }

    if data.starts_with(b"#EXTM3U") || data.starts_with(b"\xEF\xBB\xBF#EXTM3U") {
        return InputFormat::Hls;
    }
    if data.len() >= TS_PACKET_SIZE
        && data[0] == TS_SYNC_BYTE
        && (data.len() < TS_PACKET_SIZE * 2 || data[TS_PACKET_SIZE] == TS_SYNC_BYTE)
    {
        return InputFormat::MpegTs;
    }
    InputFormat::Isobmff
}

fn verify_bytes(format: InputFormat, data: &[u8]) -> ConformanceReport {
    match format {
        InputFormat::Isobmff => parse_isobmff(data),
        InputFormat::MpegTs => parse_mpeg_ts(data),
        InputFormat::Hls => parse_hls(data),
    }
}

fn print_usage() {
    eprintln!("Usage: safarium-conformance-rs [--format isobmff|ts|hls] <file>");
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() || args.iter().any(|a| a == "-h" || a == "--help") {
        print_usage();
        return if args.is_empty() {
            ExitCode::from(2)
        } else {
            ExitCode::SUCCESS
        };
    }

    let mut forced_format: Option<InputFormat> = None;
    let mut target_path: Option<String> = None;
    let mut i = 0;

    while i < args.len() {
        match args[i].as_str() {
            "--format" | "-f" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: --format requires an argument (isobmff|ts|hls)");
                    return ExitCode::from(2);
                }
                forced_format = match args[i].to_ascii_lowercase().as_str() {
                    "isobmff" | "mp4" | "mov" | "cmaf" => Some(InputFormat::Isobmff),
                    "ts" | "mpeg-ts" | "mpegts" => Some(InputFormat::MpegTs),
                    "hls" | "m3u8" => Some(InputFormat::Hls),
                    other => {
                        eprintln!("error: unknown format `{}`", other);
                        return ExitCode::from(2);
                    }
                };
            }
            arg if arg.starts_with('-') => {
                eprintln!("error: unknown flag `{}`", arg);
                return ExitCode::from(2);
            }
            path => {
                target_path = Some(path.to_string());
            }
        }
        i += 1;
    }

    let path_str = match target_path {
        Some(p) => p,
        None => {
            print_usage();
            return ExitCode::from(2);
        }
    };

    let path = Path::new(&path_str);
    let data = match fs::read(path) {
        Ok(d) => d,
        Err(err) => {
            eprintln!("error: failed to read `{}`: {}", path_str, err);
            return ExitCode::from(2);
        }
    };

    let format = forced_format.unwrap_or_else(|| detect_format(path, &data));
    let report = match format {
        InputFormat::Hls => parse_hls_with_base_dir(&data, path.parent()),
        _ => verify_bytes(format, &data),
    };
    println!("{}", report.to_json());

    if report.passed {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

// ============================================================================
// Unit Tests & Deterministic Seeded Malformed-Input Fuzzing Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn make_box(fourcc: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let total = (8 + payload.len()) as u32;
        let mut out = Vec::with_capacity(8 + payload.len());
        out.extend_from_slice(&total.to_be_bytes());
        out.extend_from_slice(fourcc);
        out.extend_from_slice(payload);
        out
    }

    fn make_visual_sample_entry(codec: &[u8; 4], children: &[u8]) -> Vec<u8> {
        let mut payload = vec![0u8; 78];
        payload.extend_from_slice(children);
        make_box(codec, &payload)
    }

    fn make_stsd(entries: &[u8], count: u32) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&[0u8; 4]); // version + flags
        payload.extend_from_slice(&count.to_be_bytes());
        payload.extend_from_slice(entries);
        make_box(b"stsd", &payload)
    }

    fn make_synthetic_hevc_mp4() -> Vec<u8> {
        // ftyp: isom / mp42 / hvc1
        let mut ftyp_payload = Vec::new();
        ftyp_payload.extend_from_slice(b"mp42");
        ftyp_payload.extend_from_slice(&0u32.to_be_bytes());
        ftyp_payload.extend_from_slice(b"isom");
        ftyp_payload.extend_from_slice(b"mp42");
        let ftyp = make_box(b"ftyp", &ftyp_payload);

        // hvcC: Main10 (profile_idc=2), 4:2:0 (1), 10-bit luma/chroma (2 -> +8=10)
        let mut hvcc_payload = vec![0u8; 23];
        hvcc_payload[0] = 1; // configurationVersion
        hvcc_payload[1] = 2; // general_profile_idc = Main 10
        hvcc_payload[12] = 120; // level 4.0
        hvcc_payload[16] = 0xFC | 0x01; // chroma_format_idc = 1 (4:2:0)
        hvcc_payload[17] = 0xF8 | 0x02; // bitDepthLumaMinus8 = 2 -> 10-bit
        hvcc_payload[18] = 0xF8 | 0x02; // bitDepthChromaMinus8 = 2 -> 10-bit
        hvcc_payload[22] = 3; // numOfArrays
        let hvcc = make_box(b"hvcC", &hvcc_payload);

        // dvcC: DV Profile 8, level 6, RPU+BL, compat=4 (HLG)
        let dvcc_payload = vec![1, 0, (8 << 1), (6 << 3) | 0x05, 0x40, 0, 0, 0];
        let dvcc = make_box(b"dvcC", &dvcc_payload);

        // colr: nclx BT.2020 (9), PQ (16), BT.2020 NCL (9), limited range
        let mut colr_payload = Vec::new();
        colr_payload.extend_from_slice(b"nclx");
        colr_payload.extend_from_slice(&9u16.to_be_bytes());
        colr_payload.extend_from_slice(&16u16.to_be_bytes());
        colr_payload.extend_from_slice(&9u16.to_be_bytes());
        colr_payload.push(0x00);
        let colr = make_box(b"colr", &colr_payload);

        // mdcv: 24 bytes
        let mut mdcv_payload = vec![0u8; 24];
        mdcv_payload[12..14].copy_from_slice(&15635u16.to_be_bytes());
        mdcv_payload[14..16].copy_from_slice(&16450u16.to_be_bytes());
        mdcv_payload[16..20].copy_from_slice(&10_000_000u32.to_be_bytes());
        mdcv_payload[20..24].copy_from_slice(&50u32.to_be_bytes());
        let mdcv = make_box(b"mdcv", &mdcv_payload);

        // clli: 1000 nits MaxCLL, 400 nits MaxFALL
        let mut clli_payload = Vec::new();
        clli_payload.extend_from_slice(&1000u16.to_be_bytes());
        clli_payload.extend_from_slice(&400u16.to_be_bytes());
        let clli = make_box(b"clli", &clli_payload);

        let mut sample_children = Vec::new();
        sample_children.extend_from_slice(&hvcc);
        sample_children.extend_from_slice(&dvcc);
        sample_children.extend_from_slice(&colr);
        sample_children.extend_from_slice(&mdcv);
        sample_children.extend_from_slice(&clli);

        let hvc1 = make_visual_sample_entry(b"hvc1", &sample_children);
        let stsd = make_stsd(&hvc1, 1);
        let stbl = make_box(b"stbl", &stsd);
        let minf = make_box(b"minf", &stbl);
        let mdia = make_box(b"mdia", &minf);
        let trak = make_box(b"trak", &mdia);
        let moov = make_box(b"moov", &trak);

        // Two CMAF moof fragments with monotonic tfdt (0 and 90000)
        let mut tfdt1_p = vec![1, 0, 0, 0];
        tfdt1_p.extend_from_slice(&0u64.to_be_bytes());
        let moof1 = make_box(b"moof", &make_box(b"traf", &make_box(b"tfdt", &tfdt1_p)));

        let mut tfdt2_p = vec![1, 0, 0, 0];
        tfdt2_p.extend_from_slice(&90_000u64.to_be_bytes());
        let moof2 = make_box(b"moof", &make_box(b"traf", &make_box(b"tfdt", &tfdt2_p)));

        let mut file = Vec::new();
        file.extend_from_slice(&ftyp);
        file.extend_from_slice(&moov);
        file.extend_from_slice(&moof1);
        file.extend_from_slice(&moof2);
        file
    }

    #[test]
    fn test_isobmff_hevc_hdr_cmaf_conformance_passes() {
        let data = make_synthetic_hevc_mp4();
        let report = parse_isobmff(&data);
        assert!(report.passed, "violations: {:?}", report.violations);
        assert_eq!(report.format, "cmaf");
        let json = report.to_json();
        assert!(json.contains("\"passed\":true"));
        assert!(json.contains("\"general_profile_idc\":2"));
        assert!(json.contains("\"bit_depth_luma\":10"));
        assert!(json.contains("\"chroma_subsampling\":\"4:2:0\""));
        assert!(json.contains("\"dv_profile\":8"));
        assert!(json.contains("\"colour_primaries\":9"));
        assert!(json.contains("\"max_content_light_level\":1000"));
        assert!(json.contains("\"tfdt\":[0,90000]"));
    }

    #[test]
    fn test_isobmff_avcc_and_non_monotonic_tfdt_detected() {
        let ftyp = make_box(b"ftyp", b"isom\0\0\0\0isom");
        let avcc = make_box(b"avcC", &[1, 100, 0, 40, 0xFF, 0xE1, 0]);
        let avc1 = make_visual_sample_entry(b"avc1", &avcc);
        let moov = make_box(
            b"moov",
            &make_box(
                b"trak",
                &make_box(
                    b"mdia",
                    &make_box(b"minf", &make_box(b"stbl", &make_stsd(&avc1, 1))),
                ),
            ),
        );

        let mut tfdt_a = vec![0, 0, 0, 0];
        tfdt_a.extend_from_slice(&180_000u32.to_be_bytes());
        let mut tfdt_b = vec![0, 0, 0, 0];
        tfdt_b.extend_from_slice(&90_000u32.to_be_bytes());

        let mut data = Vec::new();
        data.extend_from_slice(&ftyp);
        data.extend_from_slice(&moov);
        data.extend_from_slice(&make_box(
            b"moof",
            &make_box(b"traf", &make_box(b"tfdt", &tfdt_a)),
        ));
        data.extend_from_slice(&make_box(
            b"moof",
            &make_box(b"traf", &make_box(b"tfdt", &tfdt_b)),
        ));

        let report = parse_isobmff(&data);
        assert!(!report.passed);
        assert!(report
            .violations
            .iter()
            .any(|v| v.contains("Non-monotonic `tfdt`")));
        assert!(report.to_json().contains("\"avc_profile_indication\":100"));
    }

    fn make_ts_packet(pid: u16, pusi: bool, cc: u8, payload: &[u8]) -> [u8; TS_PACKET_SIZE] {
        let mut pkt = [0xFFu8; TS_PACKET_SIZE];
        pkt[0] = TS_SYNC_BYTE;
        pkt[1] = (if pusi { 0x40 } else { 0x00 }) | ((pid >> 8) as u8 & 0x1F);
        pkt[2] = (pid & 0xFF) as u8;
        pkt[3] = 0x10 | (cc & 0x0F); // payload only
        let copy_len = payload.len().min(TS_PACKET_SIZE - 4);
        pkt[4..4 + copy_len].copy_from_slice(&payload[..copy_len]);
        pkt
    }

    fn make_valid_ts() -> Vec<u8> {
        // PAT: pointer=0, table_id=0x00, section_length=13, program 1 -> PMT PID 0x0100
        let pat_payload: [u8; 17] = [
            0x00, // pointer_field
            0x00, // table_id (PAT)
            0xB0, 0x0D, // section_length = 13
            0x00, 0x01, // transport_stream_id
            0xC1, 0x00, 0x00, // version/current/sec/last
            0x00, 0x01, // program_number = 1
            0xE1, 0x00, // PMT PID = 0x0100
            0x00, 0x00, 0x00, 0x00, // CRC32 placeholder
        ];
        // PMT: pointer=0, table_id=0x02, section_length=18, PCR=0x0101, HEVC (0x24) on PID 0x0101
        let pmt_payload: [u8; 22] = [
            0x00, // pointer_field
            0x02, // table_id (PMT)
            0xB0, 0x12, // section_length = 18
            0x00, 0x01, // program_number = 1
            0xC1, 0x00, 0x00,
            0xE1, 0x01, // PCR PID = 0x0101
            0xF0, 0x00, // program_info_length = 0
            0x24, // stream_type = HEVC
            0xE1, 0x01, // ES PID = 0x0101
            0xF0, 0x00, // es_info_length = 0
            0x00, 0x00, 0x00, 0x00, // CRC32 placeholder
        ];

        let mut ts = Vec::new();
        ts.extend_from_slice(&make_ts_packet(0x0000, true, 0, &pat_payload));
        ts.extend_from_slice(&make_ts_packet(0x0100, true, 0, &pmt_payload));
        ts.extend_from_slice(&make_ts_packet(0x0101, true, 0, &[0, 0, 1, 0xE0]));
        ts.extend_from_slice(&make_ts_packet(0x0101, false, 1, &[1, 2, 3, 4]));
        ts
    }

    #[test]
    fn test_mpeg_ts_valid_and_continuity_break() {
        let valid = make_valid_ts();
        let report = parse_mpeg_ts(&valid);
        assert!(report.passed, "violations: {:?}", report.violations);
        assert!(report.to_json().contains("\"pat_packets\":1"));
        assert!(report.to_json().contains("\"pmt_packets\":1"));
        assert!(report.to_json().contains("\"stream_type\":36")); // 0x24 HEVC

        // Break continuity counter on packet 3 (PID 0x0101: 0 -> 5 instead of 1)
        let mut broken = valid.clone();
        broken[3 * TS_PACKET_SIZE + 3] = 0x10 | 0x05;
        let bad_report = parse_mpeg_ts(&broken);
        assert!(!bad_report.passed);
        assert!(bad_report
            .violations
            .iter()
            .any(|v| v.contains("Continuity counter jump")));
    }

    #[test]
    fn test_hls_master_and_media_playlists() {
        let master = "\
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS=\"hvc1.2.4.L120.90\"
1080p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS=\"hvc1.2.4.L93.90\"
720p/index.m3u8
";
        let master_rep = parse_hls(master.as_bytes());
        assert!(master_rep.passed, "violations: {:?}", master_rep.violations);
        assert!(master_rep.to_json().contains("\"stream_inf_count\":2"));

        let media = "\
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4.000,
seg000.m4s
#EXTINF:3.960,
seg001.m4s
#EXT-X-ENDLIST
";
        let media_rep = parse_hls(media.as_bytes());
        assert!(media_rep.passed, "violations: {:?}", media_rep.violations);
        assert!(media_rep.to_json().contains("\"has_endlist\":true"));
        assert!(media_rep.to_json().contains("\"segment_count\":2"));

        let bad_media = "\
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXTINF:9.500,
seg000.m4s
";
        let bad_rep = parse_hls(bad_media.as_bytes());
        assert!(!bad_rep.passed);
        assert!(bad_rep.violations.iter().any(|v| v.contains("#EXTM3U")));
        assert!(bad_rep
            .violations
            .iter()
            .any(|v| v.contains("exceeds `#EXT-X-TARGETDURATION`")));
    }

    #[test]
    fn test_ll_hls_validation_passes_and_catches_missing_part() {
        let unique = format!(
            "safarium-llhls-test-{}",
            std::process::id()
        );
        let dir = env::temp_dir().join(unique);
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create temp ll-hls test dir");

        // Part 0: valid CMAF segment starting with `styp` followed by `moof`.
        let mut part0 = make_box(b"styp", b"cmfc\0\0\0\0msdhmsix");
        part0.extend_from_slice(&make_box(b"moof", &[0u8; 16]));
        fs::write(dir.join("part_0000.m4s"), &part0).expect("write part_0000.m4s");

        // Part 1: valid CMAF chunk starting directly with `moof`.
        let part1 = make_box(b"moof", &[0u8; 16]);
        fs::write(dir.join("part_0001.m4s"), &part1).expect("write part_0001.m4s");

        // Invalid non-CMAF part for negative test.
        fs::write(dir.join("part_bad.m4s"), b"NOT_ISOBMFF_DATA").expect("write part_bad.m4s");

        let valid_ll_hls = "\
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.500
#EXT-X-PART-INF:PART-TARGET=0.500
#EXT-X-MAP:URI=\"init.mp4\"
#EXT-X-PART:DURATION=0.500,URI=\"part_0000.m4s\",INDEPENDENT=YES
#EXT-X-PART:DURATION=0.520,URI=\"part_0001.m4s\"
#EXTINF:1.020,
seg_0000.m4s
#EXT-X-ENDLIST
";
        let ok_rep = parse_hls_with_base_dir(valid_ll_hls.as_bytes(), Some(&dir));
        assert!(ok_rep.passed, "violations: {:?}", ok_rep.violations);
        let ok_json = ok_rep.to_json();
        assert!(ok_json.contains("\"is_ll_hls\":true"));
        assert!(ok_json.contains("\"part_count\":2"));
        assert!(ok_json.contains("\"independent_part_count\":1"));

        // Missing part file must fail cleanly.
        let missing_part_playlist = "\
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:2
#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.200
#EXT-X-PART-INF:PART-TARGET=0.500
#EXT-X-PART:DURATION=0.500,URI=\"part_0000.m4s\",INDEPENDENT=YES
#EXT-X-PART:DURATION=0.500,URI=\"part_missing.m4s\"
#EXTINF:1.000,
seg_0000.m4s
#EXT-X-ENDLIST
";
        let missing_rep = parse_hls_with_base_dir(missing_part_playlist.as_bytes(), Some(&dir));
        assert!(!missing_rep.passed);
        assert!(missing_rep
            .violations
            .iter()
            .any(|v| v.contains("missing part file") && v.contains("part_missing.m4s")));

        // Invalid CMAF box, excessive part duration, and too-small PART-HOLD-BACK must all be caught.
        let bad_ll_hls = "\
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:2
#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=0.700
#EXT-X-PART-INF:PART-TARGET=0.500
#EXT-X-PART:DURATION=0.800,URI=\"part_bad.m4s\"
#EXTINF:0.800,
seg_0000.m4s
";
        let bad_rep = parse_hls_with_base_dir(bad_ll_hls.as_bytes(), Some(&dir));
        assert!(!bad_rep.passed);
        assert!(bad_rep
            .violations
            .iter()
            .any(|v| v.contains("PART-HOLD-BACK")));
        assert!(bad_rep
            .violations
            .iter()
            .any(|v| v.contains("PART-TARGET * 1.15")));
        assert!(bad_rep
            .violations
            .iter()
            .any(|v| v.contains("styp") && v.contains("moof")));

        let _ = fs::remove_dir_all(&dir);
    }

    struct XorShift64(u64);
    impl XorShift64 {
        fn next_u64(&mut self) -> u64 {
            let mut x = self.0;
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            self.0 = x;
            x
        }
        fn next_byte(&mut self) -> u8 {
            (self.next_u64() & 0xFF) as u8
        }
    }

    #[test]
    fn test_deterministic_seeded_fuzzing_zero_panics() {
        let mut rng = XorShift64(0x5AFA_14B0_C0DF_9911);
        let base_mp4 = make_synthetic_hevc_mp4();
        let base_ts = make_valid_ts();

        // Explicit adversarial ISOBMFF edge cases: size=0, size=1 with u64::MAX, u32::MAX, deeply nested moov.
        let mut adversarial: Vec<Vec<u8>> = vec![
            vec![],
            vec![0, 0, 0, 0],
            vec![0, 0, 0, 1, b'f', b't', b'y', b'p'],
            vec![
                0, 0, 0, 1, b'm', b'o', b'o', b'v', 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            ],
            vec![0xFF, 0xFF, 0xFF, 0xFF, b'm', b'o', b'o', b'v', 0, 0, 0, 0],
            vec![0, 0, 0, 7, b'f', b't', b'y', b'p'],
            vec![0, 0, 0, 8, b'u', b'u', b'i', b'd'],
        ];

        // 45-deep nested `moov` boxes (must hit MAX_ISOBMFF_DEPTH cleanly without stack overflow).
        let mut deep = vec![0u8; 8];
        deep[3] = 8;
        deep[4..8].copy_from_slice(b"free");
        for _ in 0..45 {
            deep = make_box(b"moov", &deep);
        }
        adversarial.push(deep);

        for case in &adversarial {
            let r1 = parse_isobmff(case);
            let _ = r1.to_json();
            let r2 = parse_mpeg_ts(case);
            let _ = r2.to_json();
            let r3 = parse_hls(case);
            let _ = r3.to_json();
        }

        // 300 seeded truncations & byte mutations on valid MP4 + TS + pure random garbage.
        for iter in 0..300usize {
            let mode = iter % 3;
            let mut buf = match mode {
                0 => {
                    let cut = (rng.next_u64() as usize) % (base_mp4.len() + 1);
                    let mut b = base_mp4[..cut].to_vec();
                    let flips = 1 + ((rng.next_u64() as usize) % 6);
                    for _ in 0..flips {
                        if !b.is_empty() {
                            let idx = (rng.next_u64() as usize) % b.len();
                            b[idx] = rng.next_byte();
                        }
                    }
                    b
                }
                1 => {
                    let cut = (rng.next_u64() as usize) % (base_ts.len() + 1);
                    let mut b = base_ts[..cut].to_vec();
                    if !b.is_empty() {
                        let idx = (rng.next_u64() as usize) % b.len();
                        b[idx] ^= rng.next_byte();
                    }
                    b
                }
                _ => {
                    let len = (rng.next_u64() as usize) % 512;
                    (0..len).map(|_| rng.next_byte()).collect()
                }
            };

            // Occasionally inject overflowing sizes at random offsets.
            if buf.len() >= 8 && (iter % 5 == 0) {
                buf[0] = 0xFF;
                buf[1] = 0xFF;
                buf[2] = 0xFF;
                buf[3] = 0xFF;
            }

            let _ = parse_isobmff(&buf).to_json();
            let _ = parse_mpeg_ts(&buf).to_json();
            let _ = parse_hls(&buf).to_json();
        }
    }
}
