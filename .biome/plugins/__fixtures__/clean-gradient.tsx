// clean-gradient.tsx — should pass no-tailwind-v3-gradient rule

export function GoodGradient() {
  return (
    <div>
      {/* correct: Tailwind v4 gradient syntax */}
      <div className="bg-linear-to-br from-blue-500 to-purple-500">test</div>
      <div className="bg-linear-to-t from-green-400">test</div>
      <div className="bg-linear-to-bl to-red-600">test</div>
    </div>
  )
}
