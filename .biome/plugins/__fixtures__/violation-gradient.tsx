// violation-gradient.tsx — intentional violations for testing no-tailwind-v3-gradient rule
// These are fixture files, not real code — do not delete

export function BadGradient() {
  return (
    <div>
      {/* violation: Tailwind v3 gradient syntax */}
      <div className="bg-gradient-to-br from-blue-500 to-purple-500">test</div>
      <div className="bg-gradient-to-t from-green-400">test</div>
      <div className="bg-gradient-to-bl to-red-600">test</div>
    </div>
  )
}
