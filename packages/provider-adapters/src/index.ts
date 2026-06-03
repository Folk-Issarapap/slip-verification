/**
 * Abstraction for Slip2Go and other slip verification providers
 */

export interface SlipVerificationResult {
  isValid: boolean
  amount: number
  senderBank: string
  receiverBank: string
  referenceNo: string
  rawResponse?: unknown
}

export interface SlipProviderAdapter {
  verifySlip(fileUrlOrBuffer: string | Buffer): Promise<SlipVerificationResult>
}
