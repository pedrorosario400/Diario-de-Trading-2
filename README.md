# Diario de Trading

## Puesta en marcha
1. Ejecuta `001_schema.sql` en Supabase (ya hecho).
2. En Supabase > Authentication > Providers > Email: deja activa "Confirm email".
3. En Authentication > URL Configuration: Site URL `http://localhost:3000` y en Redirect URLs añade `http://localhost:3000/auth/callback` (y tu dominio de producción cuando despliegues).
4. `cp .env.example .env.local` y pega la URL y la clave anon.
5. `npm install && npm run dev` y abre http://localhost:3000

## Flujo
Registro -> verificar correo -> "Solicitud en revisión" -> el admin aprueba en /admin -> acceso al diario.
Vencida/suspendida/rechazada -> pantalla /estado (los datos nunca se borran).
