#!/usr/bin/env python3
import pathlib
import sys
import zlib


def stream(dictionary: bytes, payload: bytes) -> bytes:
    return dictionary[:-2] + b" /Length " + str(len(payload)).encode() + b">>\nstream\n" + payload + b"\nendstream"


def write_pdf(path: pathlib.Path, *, jpeg: bytes, text="DropShelf vector text", attachment=b"attachment-payload", title="Strict Fixture", unused="must survive", reference_unused=False, signed=False, xfa=False, external_stream=False, trailer_signature=False, bad_content=False, id_mode="valid", c2pa_relationship=False, c2pa_subtype=False):
    content = (
        b"q 0.2 0.4 0.8 rg 30 40 180 90 re f Q\n"
        b"BT /F1 18 Tf 40 170 Td (" + text.encode("ascii") + b") Tj ET\n"
        b"q 36 0 0 36 245 15 cm /Im1 Do Q\n"
    )
    if bad_content:
        content = b"BT /F1 12 Tf (unterminated text Tj ET"
    xmp = b'<?xpacket begin=""?><x:xmpmeta xmlns:x="adobe:ns:meta/"><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/"><rdf:Alt xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:li xml:lang="x-default">' + title.encode("ascii") + b'</rdf:li></rdf:Alt></dc:title></x:xmpmeta><?xpacket end="w"?>'
    objects = {
        1: b"<< /Type /Catalog /Pages 2 0 R /Outlines 8 0 R /AcroForm 10 0 R /Names << /EmbeddedFiles 12 0 R >> /Metadata 9 0 R /StructTreeRoot 16 0 R /MarkInfo << /Marked true >> /Lang (en-US) /PageMode /UseOutlines >>",
        2: b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        3: b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 240] /Rotate 0 /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 19 0 R >> >> /Contents 4 0 R /Annots [6 0 R 11 0 R] /StructParents 0 >>",
        4: stream(b"<< /Filter /FlateDecode >>", zlib.compress(content, 9)),
        5: b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        6: b"<< /Type /Annot /Subtype /Link /Rect [35 160 270 190] /Border [0 0 0] /A << /S /URI /URI (https://example.com/a?b=1) >> >>",
        7: b"<< /Unused true /Value (" + unused.encode("ascii") + b") /Cycle 7 0 R >>",
        8: b"<< /Type /Outlines /First 17 0 R /Last 17 0 R /Count 1 >>",
        9: stream(b"<< /Type /Metadata /Subtype /XML >>", xmp),
        10: b"<< /Fields [11 0 R] /NeedAppearances false" + (b" /XFA (unsupported)" if xfa else b"") + b" >>",
        11: b"<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Alice) /Ff 0 /Rect [40 100 180 125] /P 3 0 R /AP << /N 18 0 R >> >>",
        12: b"<< /Names [(note.txt) 13 0 R] >>",
        13: b"<< /Type /Filespec /F (note.txt) /UF (note.txt) /Desc (fixture attachment) /EF << /F 14 0 R >> >>",
        14: stream(b"<< /Type /EmbeddedFile /Subtype /text#2fplain /Params << /Size " + str(len(attachment)).encode() + b" >> >>", attachment),
        15: b"<< /Producer (DropShelf test) /Title (" + title.encode("ascii") + b") /Custom (preserve me) >>",
        16: b"<< /Type /StructTreeRoot /K [<< /Type /StructElem /S /Document /P 16 0 R /Pg 3 0 R /K 0 >>] /ParentTree << /Nums [0 [16 0 R]] >> >>",
        17: b"<< /Title (Fixture bookmark) /Parent 8 0 R /Dest [3 0 R /XYZ 0 240 1] >>",
        18: stream(b"<< /Type /XObject /Subtype /Form /BBox [0 0 140 25] /Resources << /Font << /F1 5 0 R >> >> >>", b"BT /F1 10 Tf 2 8 Td (Alice) Tj ET"),
        19: stream(b"<< /Type /XObject /Subtype /Image /Width 32 /Height 32 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode >>", jpeg),
    }
    if signed:
        objects[21] = b"<< /Type /Sig /FT /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange [0 100 200 300] /Contents <01020304> >>"
        objects[10] = objects[10].replace(b"/Fields [11 0 R]", b"/Fields [11 0 R 21 0 R]")[:-2] + b" /SigFlags 3 >>"
    if reference_unused:
        objects[1] = objects[1][:-2] + b" /Private 7 0 R >>"
    if c2pa_relationship:
        objects[1] = objects[1][:-2] + b" /AF [13 0 R] >>"
        objects[13] = objects[13][:-2] + b" /AFRelationship /C2PA_Manifest >>"
    if c2pa_subtype:
        objects[14] = objects[14].replace(b"/Subtype /text#2fplain", b"/Subtype /application#2Fc2pa")
    if external_stream:
        objects[20] = stream(b"<< /F (external.bin) >>", b"")
        objects[1] = objects[1][:-2] + b" /External 20 0 R >>"

    header = b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n"
    body = bytearray(header)
    offsets = {0: 0}
    for number in sorted(objects):
        offsets[number] = len(body)
        body += f"{number} 0 obj\n".encode() + objects[number] + b"\nendobj\n"
    xref_offset = len(body)
    max_object = max(objects)
    body += f"xref\n0 {max_object + 1}\n".encode()
    body += b"0000000000 65535 f \n"
    for number in range(1, max_object + 1):
        if number in offsets:
            body += f"{offsets[number]:010d} 00000 n \n".encode()
        else:
            body += b"0000000000 00000 f \n"
    trailer_extra = " /ByteRange [0 1 2 3]" if trailer_signature else ""
    trailer_id = {
        "valid": " /ID [<00112233445566778899aabbccddeeff><ffeeddccbbaa99887766554433221100>]",
        "malformed": " /ID [(only-one)]",
        "none": "",
    }[id_mode]
    body += f"trailer\n<< /Size {max_object + 1} /Root 1 0 R /Info 15 0 R{trailer_id}{trailer_extra} >>\nstartxref\n{xref_offset}\n%%EOF\n".encode()
    path.write_bytes(body)


def main():
    out = pathlib.Path(sys.argv[1])
    jpeg = pathlib.Path(sys.argv[2]).read_bytes()
    jpeg_with_comment = jpeg[:2] + b"\xff\xfe\x00\x06test" + jpeg[2:]
    out.mkdir(parents=True, exist_ok=True)
    write_pdf(out / "rich.pdf", jpeg=jpeg)
    write_pdf(out / "linear-source.pdf", jpeg=jpeg, reference_unused=True)
    write_pdf(out / "content-mutated.pdf", jpeg=jpeg, text="Changed vector text")
    write_pdf(out / "attachment-mutated.pdf", jpeg=jpeg, attachment=b"changed-attachment")
    write_pdf(out / "metadata-mutated.pdf", jpeg=jpeg, title="Changed metadata")
    write_pdf(out / "unused-mutated.pdf", jpeg=jpeg, unused="changed unused object")
    write_pdf(out / "jpeg-mutated.pdf", jpeg=jpeg_with_comment)
    write_pdf(out / "signed.pdf", jpeg=jpeg, signed=True)
    write_pdf(out / "trailer-signed.pdf", jpeg=jpeg, trailer_signature=True)
    write_pdf(out / "xfa.pdf", jpeg=jpeg, xfa=True)
    write_pdf(out / "external-stream.pdf", jpeg=jpeg, external_stream=True)
    write_pdf(out / "bad-content.pdf", jpeg=jpeg, bad_content=True)
    write_pdf(out / "malformed-id.pdf", jpeg=jpeg, id_mode="malformed")
    write_pdf(out / "no-id.pdf", jpeg=jpeg, id_mode="none")
    write_pdf(out / "c2pa-relationship.pdf", jpeg=jpeg, c2pa_relationship=True)
    write_pdf(out / "c2pa-subtype.pdf", jpeg=jpeg, c2pa_subtype=True)
    data = (out / "rich.pdf").read_bytes()
    (out / "broken.pdf").write_bytes(data[: len(data) // 2])


if __name__ == "__main__":
    main()
