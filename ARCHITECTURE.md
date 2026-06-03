# สรุปโครงสร้างของ Project (White-label Slip Verification)

หลังจากที่ได้ปรับปรุงและวางโครงสร้างใหม่ทั้งหมด โปรเจ็กต์ของคุณทำงานในลักษณะ **Monorepo (pnpm + Turborepo)** บนระบบนิเวศของ Cloudflare แบบ 100% โดยแบ่งสัดส่วนการทำงานอย่างชัดเจนดังนี้ครับ:

## 1. ส่วนแอปพลิเคชันหลัก (`apps/`)

### `apps/api` (Backend)
- ใช้ **Hono** เป็น Core Framework เบา โหลดเร็ว เหมาะกับ Edge Runtime (Cloudflare Workers)
- คงเหลือ Middleware ที่จำเป็นทั้งหมดไว้ให้ (CORS, Security headers, Rate limit, Logger) รวมถึงการตั้งค่า Environment Variables (เช่น การต่อ D1, R2)
- พร้อมสำหรับการใช้ **Zod** คู่กับ **OpenAPIHono** เพื่อทำ API Spec และรองรับการนำ Database ORM (เช่น Drizzle) มาสวมใส่ได้ทันที

### `apps/admin` (Frontend - ระบบหลังบ้าน)
- สร้างด้วย **Next.js (vinext App Router)** โครงสร้างคลีนพร้อมหน้า Dashboard ว่างเปล่า
- รองรับ **Tailwind CSS**, **react-query** และ **next-intl** เพื่อเตรียมพร้อมทำระบบหลายภาษา (TH/EN)
- ตั้งค่าให้รันบน **Port 3000**

### `apps/customer` (Frontend - ระบบหน้าบ้าน)
- แอปพลิเคชันสำหรับลูกค้า โคลนโครงสร้างสถาปัตยกรรมมาจาก `admin` ทั้งหมด ทำให้เขียนโค้ดได้ด้วยมาตรฐานเดียวกัน
- ตั้งค่าให้รันอิสระแยกจากกันบน **Port 3001**

## 2. ส่วนแพ็กเกจกลางที่ใช้ร่วมกัน (`packages/`)

### `packages/ui`
- ศูนย์รวม Design System ของระบบ (อิงตาม **shadcn/ui** และ **Radix Nova**)
- ไม่มี Business Logic ปะปน ทำให้ทั้ง `admin` และ `customer` สามารถดึง Component จากที่นี่ไปประกอบหน้า UI ได้ตรงกันเป๊ะ

### `packages/money`
- แพ็กเกจสำหรับคำนวณและแปลงค่าเงิน **Satang ↔ THB** ป้องกันปัญหาเลขทศนิยมผิดพลาดคลาดเคลื่อนในการทำระบบตรวจสอบยอดเงิน (Ledger/Slip)

### `packages/provider-adapters`
- พื้นที่สำหรับทำ Abstraction เชื่อมต่อบริการตรวจสอบสลิปภายนอก (Third-party)
- มี Interface กองกลาง (`SlipVerificationResult`, `SlipProviderAdapter`) เตรียมไว้ให้ หากในอนาคตต้องการเปลี่ยนจาก Slip2Go เป็นเจ้าอื่น ระบบหลักจะไม่กระทบ

### `packages/typescript-config`
- ศูนย์กลางเก็บการตั้งค่า TypeScript ให้ทั้งระบบบังคับใช้ Rule เดียวกันอย่างเข้มงวด (Type-safe)

## 🚀 ภาพรวมการทำงาน (Data Flow)

`apps/customer` (หรือ `admin`) ↔ เรียก API ไปยัง `apps/api` (Hono) ↔ ตรวจสอบและประมวลผลผ่าน **Cloudflare D1** (Database) / เก็บสลิปใน **Cloudflare R2** (Storage) ↔ ส่งข้อมูลสลิปไปตรวจสอบผ่าน `packages/provider-adapters`

---

> โครงสร้างทั้งหมดนี้ผ่านการทำ Typecheck สำเร็จสมบูรณ์แบบ 100% คุณสามารถเริ่มรัน `pnpm dev` แล้วลุยต่อเติมหน้ากาก UI กับ Business Logic โลจิกใหม่เข้าไปได้ทันทีครับ!
