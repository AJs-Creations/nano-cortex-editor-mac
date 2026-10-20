// The fake pedal's answers to the Cloud IR transfer (15 → 16), the auditions (150 → 151, 158 → 159, 148 → 149) and
// the IR delete (82 → 83), in the shapes of PROTOCOL-NOTES §15 and the Electron edition's demo pedal. Checks what the
// real pedal would: the MD5 next to the bytes, the exact index and name of a library item, the stop's transaction.

import Foundation

extension DemoState {
    /// The replies to one of these messages (body, type), or nil when `type` is none of them. Changes the IR library
    /// and the audition like the pedal would.
    mutating func answerTransfer(type: UInt32, body: [UInt8]) -> [(body: [UInt8], type: UInt32)]? {
        let f = ProtoFields.parse(body)
        switch type {
        case TransferType.uploadIR:
            // {1: 6, 3: {1: WAV, 2: MD5}, 4: product id, 5: file name} → 16 {1: 6, 3: 1, 4: {1: index, 2: name}}
            let content = f.message(3), wav = content?.first(1)?.bytes ?? [], filename = f.string(5) ?? ""
            var why = ""
            if wav.isEmpty { why = "No WAV data" }
            else if content?.string(2) != Transfer.md5Hex(wav) { why = "MD5 mismatch" }
            else if !IRTransfer.isProductId(f.string(4) ?? "") { why = "No product id" }
            else if !filename.lowercased().hasSuffix(".wav") { why = "Not a .wav file name" }
            guard why.isEmpty else { return [(ProtoWriter().int(1, 6).int(3, 0).string(5, why).build(), TransferType.uploadIRReply)] }
            let name = String(filename.dropLast(4))
            userIRs.append(name)
            let record = ProtoWriter().int(1, UInt64(userIRs.count - 1)).string(2, name)
            return [(ProtoWriter().int(1, 6).int(3, 1).message(4, record).build(), TransferType.uploadIRReply)]

        case TransferType.capturePreview:
            // {5: {1: {1: cns, 2: MD5}, 2: record}, 7: 2, 8: 1} → 151 {1: 6, 3: 1, 4: {1: 2, 2: name, 3: hash}}
            let object = f.message(5), content = object?.message(1), cns = content?.first(1)?.bytes ?? []
            let record = CaptureRecord.decode(object?.message(2) ?? ProtoFields.parse([]))
            let ok = !cns.isEmpty && content?.string(2) == Transfer.md5Hex(cns)
            if ok { auditioning = "capture: " + record.name }
            let rec = ProtoWriter().int(1, 2).string(2, record.name).string(3, record.hash)
            return [(ProtoWriter().int(1, 6).int(3, ok ? 1 : 0).message(4, rec).build(), TransferType.capturePreviewReply)]

        case TransferType.irPreview:
            // {3 (factory) or 4 (user): {1: index, 2: name}, 8: 1} → 159 {1: 6, 3: 1, 4: {2: name}} when that item is there
            let factory = f.message(3) != nil, rec = f.message(3) ?? f.message(4)
            let index = Int(rec?.int(1) ?? 0), name = rec?.string(2) ?? "", list = factory ? factoryIRs : userIRs
            let ok = rec != nil && f.int(8) == 1 && index < list.count && IRTransfer.sameName(list[index], name)
            if ok { auditioning = "ir: " + name }
            return [(ProtoWriter().int(1, 6).int(3, ok ? 1 : 0).message(4, ProtoWriter().string(2, name)).build(), TransferType.irPreviewReply)]

        case TransferType.auditionStop:
            // {2: transaction, 3 or 4: 0} → 149 {1: 1, 2: same transaction, 3: 1}; the hook answers a refusal (status 0).
            let transaction = f.int(2) ?? 0
            if !refuseAuditionStop { auditioning = nil }
            return [(ProtoWriter().int(1, 1).int(2, transaction).int(3, refuseAuditionStop ? 0 : 1).build(), TransferType.auditionStopReply)]

        case TransferType.deleteIR:
            // {1: 2, 4: {1: index, 2: name}} → 83 {1: 6, 3: 1}; indices after it shift down, as in type 77
            let rec = f.message(4), index = Int(rec?.int(1) ?? 0), name = rec?.string(2) ?? ""
            let removed = f.int(1) == 2 && rec != nil && index < userIRs.count && IRTransfer.sameName(userIRs[index], name)
            if removed { userIRs.remove(at: index) }
            return [(ProtoWriter().int(1, 6).int(3, removed ? 1 : 0).build(), TransferType.deleteIRReply)]

        default:
            return nil
        }
    }
}
