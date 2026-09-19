//! Clipboard image support: limits mirrored from `src/imageLimits.ts`, header-only
//! dimension parsing (no decoder in the helper) and a small base64 encoder.

pub const MAX_IMAGE_FILE_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_IMAGE_DIMENSION: u32 = 8_192;
pub const MAX_IMAGE_PIXELS: u64 = 16_000_000;
pub const MAX_IMAGES_PER_NOTE: usize = 20;
/// Over every image of a note: the desktop edition refuses to export or
/// restore a note past this, so a paste that would cross it is refused here.
pub const MAX_IMAGE_PIXELS_PER_NOTE: u64 = 16_000_000;
/// Over an animation's frames, as the desktop edition validates on export and
/// import: a paste past either would make it refuse to back up the note.
pub const MAX_ANIMATION_FRAMES: u64 = 60;
pub const MAX_ANIMATION_PIXELS: u64 = 16_000_000;

/// Preferred order when the clipboard offers several. Only formats whose
/// header this file can read: an image the guard cannot measure is refused.
pub const SUPPORTED: [&str; 3] = ["image/png", "image/jpeg", "image/gif"];

pub fn check_dimensions(w: u32, h: u32) -> Result<(), String> {
    if w == 0 || h == 0 {
        return Err("Image has no size".into());
    }
    if w > MAX_IMAGE_DIMENSION || h > MAX_IMAGE_DIMENSION {
        return Err(format!("Image is larger than {MAX_IMAGE_DIMENSION} px on a side"));
    }
    if u64::from(w) * u64::from(h) > MAX_IMAGE_PIXELS {
        return Err("Image has more than 16 megapixels".into());
    }
    Ok(())
}

/// Width and height from the file header, when the format is one we can read.
pub fn dimensions(mime: &str, bytes: &[u8]) -> Option<(u32, u32)> {
    match mime {
        "image/png" => png(bytes),
        "image/jpeg" => jpeg(bytes),
        "image/gif" => gif(bytes),
        _ => None,
    }
}

fn be32(b: &[u8]) -> u32 { u32::from_be_bytes([b[0], b[1], b[2], b[3]]) }
fn be16(b: &[u8]) -> u32 { u32::from(u16::from_be_bytes([b[0], b[1]])) }

fn png(b: &[u8]) -> Option<(u32, u32)> {
    if b.len() < 24 || &b[..8] != b"\x89PNG\r\n\x1a\n" || &b[12..16] != b"IHDR" {
        return None;
    }
    Some((be32(&b[16..20]), be32(&b[20..24])))
}

fn gif(b: &[u8]) -> Option<(u32, u32)> {
    if b.len() < 10 || (&b[..6] != b"GIF89a" && &b[..6] != b"GIF87a") {
        return None;
    }
    Some((u32::from(u16::from_le_bytes([b[6], b[7]])), u32::from(u16::from_le_bytes([b[8], b[9]]))))
}

/// Walks the JPEG segments to the first start-of-frame marker.
fn jpeg(b: &[u8]) -> Option<(u32, u32)> {
    if b.len() < 4 || b[0] != 0xFF || b[1] != 0xD8 {
        return None;
    }
    let mut i = 2;
    while i + 9 <= b.len() {
        if b[i] != 0xFF {
            return None;
        }
        let marker = b[i + 1];
        if marker == 0xFF {
            i += 1;
            continue;
        }
        let sof = matches!(marker, 0xC0..=0xCF) && !matches!(marker, 0xC4 | 0xC8 | 0xCC);
        if sof {
            return Some((be16(&b[i + 7..i + 9]), be16(&b[i + 5..i + 7])));
        }
        let len = be16(&b[i + 2..i + 4]) as usize;
        if len < 2 {
            return None;
        }
        i += 2 + len;
    }
    None
}

/// Decoded pixels over an animation's frames (the canvas charged once per
/// frame, as the desktop edition counts), 0 for a still image. Walks the GIF
/// blocks or the PNG chunks without decoding; a malformed stream is refused.
pub fn check_animation(mime: &str, bytes: &[u8]) -> Result<u64, String> {
    match mime {
        "image/gif" => gif_animation(bytes),
        "image/png" => png_animation(bytes),
        _ => Ok(0),
    }
}

/// An image's pixels as the desktop edition charges them against a note:
/// the canvas, or the animation's frames when that is more.
pub fn charged_pixels(mime: &str, bytes: &[u8], w: u32, h: u32) -> Result<u64, String> {
    Ok(check_animation(mime, bytes)?.max(u64::from(w) * u64::from(h)))
}

fn gif_animation(b: &[u8]) -> Result<u64, String> {
    let truncated = || "GIF data is truncated".to_string();
    if b.len() < 13 {
        return Err(truncated());
    }
    let (cw, ch) = gif(b).ok_or_else(truncated)?;
    let canvas = u64::from(cw) * u64::from(ch);
    let table = |packed: u8| if packed & 0x80 != 0 { 3usize << ((packed & 0x07) as usize + 1) } else { 0 };
    let mut pos = 13usize.checked_add(table(b[10])).filter(|p| *p <= b.len()).ok_or_else(truncated)?;
    let (mut frames, mut pixels) = (0u64, 0u64);
    while pos < b.len() {
        match b[pos] {
            0x3B => break,
            0x21 => {
                pos = pos.checked_add(2).filter(|p| *p <= b.len()).ok_or_else(truncated)?;
                skip_gif_sub_blocks(b, &mut pos)?;
            }
            0x2C => {
                let end = pos.checked_add(10).filter(|p| *p <= b.len()).ok_or_else(truncated)?;
                let le = |i: usize| u32::from(u16::from_le_bytes([b[pos + i], b[pos + i + 1]]));
                let (left, top, w, h) = (le(1), le(3), le(5), le(7));
                check_dimensions(w, h)?;
                if left + w > cw || top + h > ch {
                    return Err("GIF frame is outside its canvas".into());
                }
                frames += 1;
                if frames > MAX_ANIMATION_FRAMES {
                    return Err(format!("Animated images can contain at most {MAX_ANIMATION_FRAMES} frames"));
                }
                pixels += canvas;
                if pixels > MAX_ANIMATION_PIXELS {
                    return Err("Animation frames exceed 16 megapixels".into());
                }
                pos = end.checked_add(table(b[pos + 9])).and_then(|p| p.checked_add(1)).filter(|p| *p <= b.len()).ok_or_else(truncated)?;
                skip_gif_sub_blocks(b, &mut pos)?;
            }
            _ => return Err("GIF contains an invalid block".into()),
        }
    }
    if frames > 1 { Ok(pixels) } else { Ok(0) }
}

fn skip_gif_sub_blocks(b: &[u8], pos: &mut usize) -> Result<(), String> {
    loop {
        let size = *b.get(*pos).ok_or("GIF data is truncated")? as usize;
        *pos += 1;
        if size == 0 {
            return Ok(());
        }
        *pos = pos.checked_add(size).filter(|p| *p <= b.len()).ok_or("GIF data is truncated")?;
    }
}

fn png_animation(b: &[u8]) -> Result<u64, String> {
    let truncated = || "PNG chunk is truncated".to_string();
    let (cw, ch) = png(b).ok_or_else(truncated)?;
    let canvas = u64::from(cw) * u64::from(ch);
    let mut pos = 8usize;
    let (mut declared, mut frames, mut pixels) = (None, 0u64, 0u64);
    while pos + 12 <= b.len() {
        let len = be32(&b[pos..pos + 4]) as usize;
        let data = pos + 8;
        let end = data.checked_add(len).filter(|e| e.saturating_add(4) <= b.len()).ok_or_else(truncated)?;
        let kind = &b[pos + 4..pos + 8];
        if kind == b"acTL" {
            if len < 8 {
                return Err("APNG animation header is invalid".into());
            }
            let count = u64::from(be32(&b[data..data + 4]));
            if count > MAX_ANIMATION_FRAMES {
                return Err(format!("Animated images can contain at most {MAX_ANIMATION_FRAMES} frames"));
            }
            declared = Some(count);
        } else if kind == b"fcTL" {
            if len < 26 {
                return Err("APNG frame header is invalid".into());
            }
            let (w, h, left, top) = (be32(&b[data + 4..data + 8]), be32(&b[data + 8..data + 12]), be32(&b[data + 12..data + 16]), be32(&b[data + 16..data + 20]));
            check_dimensions(w, h)?;
            if u64::from(left) + u64::from(w) > u64::from(cw) || u64::from(top) + u64::from(h) > u64::from(ch) {
                return Err("APNG frame is outside its canvas".into());
            }
            frames += 1;
            pixels += canvas;
            if pixels > MAX_ANIMATION_PIXELS {
                return Err("Animation frames exceed 16 megapixels".into());
            }
        }
        pos = end + 4;
        if kind == b"IEND" {
            break;
        }
    }
    match declared {
        Some(count) if count == 0 || frames != count => Err("APNG frame count is invalid".into()),
        Some(_) => Ok(pixels),
        None => Ok(0),
    }
}

/// The note's rules before a paste, as the desktop edition applies them
/// (`validate_note_images`): at most MAX_IMAGES_PER_NOTE images,
/// MAX_IMAGE_PIXELS_PER_NOTE pixels over all of them and the title icon when
/// it is an image (its pixels count, it is not one of the images). `sources`
/// are the data URLs already in the note, `pixels` what the new image is
/// charged (`charged_pixels`).
pub fn check_note_budget(sources: &[String], title_icon: Option<&str>, pixels: u64) -> Result<(), String> {
    if sources.len() >= MAX_IMAGES_PER_NOTE {
        return Err(format!("A note holds at most {MAX_IMAGES_PER_NOTE} images"));
    }
    // An image this helper cannot measure (a format the desktop edition
    // stored) counts as none, rather than refusing every later paste.
    let icon: u64 = title_icon.filter(|i| i.starts_with("data:image/")).and_then(data_url_pixels).unwrap_or(0);
    let used: u64 = icon + sources.iter().map(|s| data_url_pixels(s).unwrap_or(0)).sum::<u64>();
    if used + pixels > MAX_IMAGE_PIXELS_PER_NOTE {
        return Err("Images in one note can total at most 16 megapixels".into());
    }
    Ok(())
}

/// Pixels of a stored image as the desktop edition charges them (canvas or
/// animation frames, whichever is more); None when the URL is not one of the
/// supported formats, is oversized, or cannot be read. An animation the walk
/// cannot follow counts its canvas.
pub fn data_url_pixels(src: &str) -> Option<u64> {
    let (mime, payload) = src.strip_prefix("data:")?.split_once(";base64,")?;
    if !SUPPORTED.contains(&mime) || payload.len() > MAX_IMAGE_FILE_BYTES / 3 * 4 + 4 {
        return None;
    }
    let bytes = unbase64(payload)?;
    let (w, h) = dimensions(mime, &bytes)?;
    Some(check_animation(mime, &bytes).unwrap_or(0).max(u64::from(w) * u64::from(h)))
}

fn unbase64(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len() / 4 * 3);
    let (mut buf, mut bits) = (0u32, 0u32);
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            _ => return None,
        };
        buf = (buf << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
            buf &= (1 << bits) - 1;
        }
    }
    Some(out)
}

pub fn base64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((bytes.len() + 2) / 3 * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_known_vectors() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"M"), "TQ==");
        assert_eq!(base64(b"Ma"), "TWE=");
        assert_eq!(base64(b"Man"), "TWFu");
        assert_eq!(base64(&[0xFF, 0xEE, 0xDD, 0x00]), "/+7dAA==");
    }

    #[test]
    fn header_dimensions_for_png_gif_jpeg() {
        let mut png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR".to_vec();
        png.extend_from_slice(&640u32.to_be_bytes());
        png.extend_from_slice(&480u32.to_be_bytes());
        assert_eq!(dimensions("image/png", &png), Some((640, 480)));
        assert_eq!(dimensions("image/png", b"not a png"), None);

        let mut gif = b"GIF89a".to_vec();
        gif.extend_from_slice(&300u16.to_le_bytes());
        gif.extend_from_slice(&200u16.to_le_bytes());
        assert_eq!(dimensions("image/gif", &gif), Some((300, 200)));

        // SOI, APP0 segment (length 4), then SOF0 with height 1080 width 1920.
        let mut jpg = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46];
        jpg.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x11, 0x08]);
        jpg.extend_from_slice(&1080u16.to_be_bytes());
        jpg.extend_from_slice(&1920u16.to_be_bytes());
        jpg.extend_from_slice(&[0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        assert_eq!(dimensions("image/jpeg", &jpg), Some((1920, 1080)));
        assert_eq!(dimensions("image/webp", b"RIFF....WEBP"), None, "unknown formats have no dimensions and are refused");
        assert!(!SUPPORTED.contains(&"image/webp"));
    }

    #[test]
    fn note_budget_counts_the_images_already_in_the_note() {
        let png = |w: u32, h: u32| {
            let mut b = b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR".to_vec();
            b.extend_from_slice(&w.to_be_bytes());
            b.extend_from_slice(&h.to_be_bytes());
            format!("data:image/png;base64,{}", base64(&b))
        };
        assert_eq!(unbase64(&base64(b"round trip, three bytes")), Some(b"round trip, three bytes".to_vec()));
        assert_eq!(unbase64("TQ=="), Some(b"M".to_vec()));
        assert_eq!(unbase64("T Q"), None);
        assert_eq!(data_url_pixels(&png(640, 480)), Some(640 * 480));
        assert_eq!(data_url_pixels("data:image/webp;base64,AAAA"), None);
        let two = vec![png(4000, 2000), png(4000, 2000)];
        assert!(check_note_budget(&two[..1], None, 4000 * 2000).is_ok(), "exactly the budget passes");
        assert!(check_note_budget(&two, None, 1).unwrap_err().contains("16 megapixels"));
        assert!(check_note_budget(&["data:image/webp;base64,AAAA".to_string()], None, 4000 * 4000).is_ok(), "an unmeasured image counts as none");
        let many: Vec<String> = (0..MAX_IMAGES_PER_NOTE).map(|_| png(1, 1)).collect();
        assert!(check_note_budget(&many, None, 1).unwrap_err().contains("20"));
        // A stored animation is charged its frames, like the desktop edition does.
        let stored = format!("data:image/gif;base64,{}", base64(&gif_frames(2000, 2000, 2)));
        assert_eq!(data_url_pixels(&stored), Some(8_000_000));
        assert!(check_note_budget(&[stored.clone(), stored.clone()], None, 1).unwrap_err().contains("16 megapixels"));
        // The title icon's pixels count (the desktop edition charges it to the
        // note), but it is not one of the 20 images.
        let icon = png(2000, 2000);
        assert!(check_note_budget(&[], Some(&icon), 12_000_001).unwrap_err().contains("16 megapixels"));
        assert!(check_note_budget(&[], Some(&icon), 12_000_000).is_ok());
        let nineteen: Vec<String> = (0..19).map(|_| png(1, 1)).collect();
        assert!(check_note_budget(&nineteen, Some(&icon), 1).is_ok(), "the icon is not an image of the note");
        assert!(check_note_budget(&[], Some("😀"), 16_000_000).is_ok(), "an emoji icon has no pixels");
        assert!(check_note_budget(&[], Some("data:image/webp;base64,AAAA"), 16_000_000).is_ok());
    }

    /// A GIF with `frames` one-pixel frames on a w×h canvas (the desktop test fixture).
    fn gif_frames(w: u16, h: u16, frames: usize) -> Vec<u8> {
        let mut gif = b"GIF89a".to_vec();
        gif.extend_from_slice(&w.to_le_bytes());
        gif.extend_from_slice(&h.to_le_bytes());
        gif.extend_from_slice(&[0, 0, 0]);
        for _ in 0..frames {
            gif.extend_from_slice(&[0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 1, 0, 0]);
        }
        gif.push(0x3B);
        gif
    }

    #[test]
    fn animation_limits_match_the_desktop_edition() {
        let over = gif_frames(1, 1, MAX_ANIMATION_FRAMES as usize + 1);
        assert!(check_animation("image/gif", &over).unwrap_err().contains("60"));
        assert_eq!(check_animation("image/gif", &gif_frames(1, 1, MAX_ANIMATION_FRAMES as usize)), Ok(60));
        assert!(check_animation("image/gif", &gif_frames(4000, 4000, 2)).unwrap_err().contains("megapixels"));
        assert_eq!(check_animation("image/gif", &gif_frames(2000, 2000, 2)), Ok(8_000_000));
        assert_eq!(check_animation("image/gif", &gif_frames(2000, 2000, 1)), Ok(0), "a still GIF is its canvas");
        assert_eq!(charged_pixels("image/gif", &gif_frames(2000, 2000, 1), 2000, 2000), Ok(4_000_000));
        assert_eq!(charged_pixels("image/gif", &gif_frames(2000, 2000, 2), 2000, 2000), Ok(8_000_000));
        let mut cut = gif_frames(1, 1, 2);
        cut.truncate(cut.len() - 3);
        assert!(check_animation("image/gif", &cut).unwrap_err().contains("truncated"));
        let mut outside = gif_frames(1, 1, 1);
        outside[13 + 5] = 2;
        assert!(check_animation("image/gif", &outside).unwrap_err().contains("canvas"));

        let chunk = |kind: &[u8], data: &[u8]| {
            let mut c = (data.len() as u32).to_be_bytes().to_vec();
            c.extend_from_slice(kind);
            c.extend_from_slice(data);
            c.extend_from_slice(&[0, 0, 0, 0]);
            c
        };
        let apng = |w: u32, h: u32, declared: u32, frames: u32| {
            let mut ihdr = w.to_be_bytes().to_vec();
            ihdr.extend_from_slice(&h.to_be_bytes());
            ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
            let mut b = b"\x89PNG\r\n\x1a\n".to_vec();
            b.extend(chunk(b"IHDR", &ihdr));
            let mut actl = declared.to_be_bytes().to_vec();
            actl.extend_from_slice(&[0, 0, 0, 0]);
            b.extend(chunk(b"acTL", &actl));
            for i in 0..frames {
                let mut fctl = i.to_be_bytes().to_vec();
                for v in [w, h, 0, 0] {
                    fctl.extend_from_slice(&v.to_be_bytes());
                }
                fctl.extend_from_slice(&[0, 1, 0, 100, 0, 0]);
                b.extend(chunk(b"fcTL", &fctl));
            }
            b.extend(chunk(b"IEND", b""));
            b
        };
        assert_eq!(check_animation("image/png", &apng(100, 100, 2, 2)), Ok(20_000));
        assert!(check_animation("image/png", &apng(1, 1, 61, 61)).unwrap_err().contains("60"));
        assert!(check_animation("image/png", &apng(4000, 4000, 2, 2)).unwrap_err().contains("megapixels"));
        assert!(check_animation("image/png", &apng(1, 1, 2, 1)).unwrap_err().contains("frame count"));
        let mut still = b"\x89PNG\r\n\x1a\n".to_vec();
        still.extend(chunk(b"IHDR", &[0, 0, 2, 128, 0, 0, 1, 224, 8, 2, 0, 0, 0]));
        still.extend(chunk(b"IEND", b""));
        assert_eq!(check_animation("image/png", &still), Ok(0), "a still PNG has no frames");
        assert!(check_animation("image/png", &still[..24]).unwrap_err().contains("truncated"), "a header alone is not a file");
        let header_only = format!("data:image/png;base64,{}", base64(&still[..24]));
        assert_eq!(data_url_pixels(&header_only), Some(640 * 480), "a stored image the walk cannot follow counts its canvas");
        assert_eq!(check_animation("image/jpeg", b"\xff\xd8"), Ok(0));
    }

    #[test]
    fn dimension_limits() {
        assert!(check_dimensions(8192, 1953).is_ok());
        assert!(check_dimensions(8193, 10).unwrap_err().contains("8192"));
        assert!(check_dimensions(4000, 4001).unwrap_err().contains("megapixels"));
        assert!(check_dimensions(0, 10).is_err());
    }
}
