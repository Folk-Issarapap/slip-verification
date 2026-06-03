// clean-card.tsx — should pass no-card-flush-className rule

export function GoodCard() {
  return (
    <div>
      {/* correct: use variant="flush" instead */}
      <Card variant="flush">test</Card>
      {/* py-0 on non-Card element is fine */}
      <div className="py-0">test</div>
    </div>
  )
}
