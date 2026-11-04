# Guía de despliegue (Vercel + Supabase)

## 1. Antes de subir
- Confirma que `.env.local` NO está en el repositorio (ya está en `.gitignore`).
- Prueba localmente: registro, aprobación, sesión, edición, calendario, CSV.
- Define tu correo de contacto: `NEXT_PUBLIC_CONTACT_EMAIL` (aparece en privacidad y términos).

## 2. Subir el código
1. Crea un repositorio PRIVADO en GitHub y sube la carpeta del proyecto.
2. En vercel.com: Add New > Project > importa el repositorio (framework: Next.js).

## 3. Variables de entorno en Vercel
| Variable | Valor |
|---|---|
| NEXT_PUBLIC_SUPABASE_URL | URL de tu proyecto Supabase |
| NEXT_PUBLIC_SUPABASE_ANON_KEY | clave anon |
| NEXT_PUBLIC_CONTACT_EMAIL | tu correo de contacto |
| QUOTES_API_KEY | (opcional) clave del proveedor de precios |
| QUOTES_DATA_STATUS | `retrasado` o `tiempo_real`, según tu plan |

Nunca pongas la clave `service_role` en Vercel ni en el código: esta app no la necesita.

## 4. Supabase (Authentication > URL Configuration)
- Site URL: `https://TU-DOMINIO`
- Redirect URLs: `https://TU-DOMINIO/auth/callback` (conserva también la de localhost para desarrollo).
- Si usas dominio propio, añádelo en Vercel > Settings > Domains y actualiza lo anterior.

## 5. Correos de verificación
El correo integrado de Supabase tiene un límite bajo de envíos por hora. Antes de abrir el registro a más gente, configura un SMTP propio (por ejemplo Resend, Brevo o Postmark) en Authentication > SMTP Settings, y personaliza la plantilla de confirmación en español.

## 6. Endurecimiento recomendado
- Authentication > Providers > Email: mantén "Confirm email" activo y sube la longitud mínima de contraseña.
- Activa la protección contra contraseñas filtradas si tu plan la ofrece.
- Revisa los límites de tasa (rate limits) de Authentication.
- Activa copias de seguridad (Database > Backups) cuando haya usuarios reales.
- Verifica en Table Editor que todas las tablas muestren RLS activo.

## 7. Prueba final en producción
1. Registra un usuario nuevo con un correo real: debe llegar el correo y quedar "Pendiente".
2. Apruébalo desde /admin: debe poder entrar.
3. Con ese usuario, confirma que NO puede abrir /admin.
4. Crea una sesión y comprueba que otro usuario no la ve.
5. Abre la app en el celular.
