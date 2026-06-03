// violation-card.tsx — intentional violations for testing no-card-flush-className rule
// These are fixture files, not real code — do not delete

export function BadCard() {
  return (
    <div>
      {/* violation: py-0 */}
      <Card className="gap-0 overflow-hidden py-0">test</Card>
      {/* violation: gap-0 only */}
      <Card className="gap-0">test</Card>
      {/* violation: py-0 only */}
      <Card className="py-0">test</Card>
    </div>
  )
}
