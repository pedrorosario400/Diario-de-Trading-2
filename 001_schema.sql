-- =====================================================================
-- DIARIO DE TRADING · Fase 1: esquema, seguridad (RLS) y administración
-- Ejecutar en Supabase: SQL Editor > New query > pegar > Run
-- =====================================================================

-- ---------- Tipos ----------
create type user_status    as enum ('pendiente','activo','rechazado','suspendido');
create type user_role      as enum ('user','admin');
create type account_type   as enum ('personal','evaluacion','fondeada');
create type loss_limit_kind as enum ('fijo','trailing_cierre','trailing_intradia');
create type daily_loss_base as enum ('balance_inicial_jornada','maximo_jornada');
create type session_state  as enum ('operada','sin_operar','cerrada');
create type plan_followed  as enum ('si','parcialmente','no');
create type result_source  as enum ('manual','trades');

-- ---------- Perfiles y suscripciones ----------
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  role user_role not null default 'user',
  status user_status not null default 'pendiente',
  registered_at timestamptz not null default now(),
  first_activated_at timestamptz,          -- fecha original de ingreso (nunca cambia)
  timezone text not null default 'America/Santo_Domingo'
);

create table subscriptions (               -- una fila por período (historial)
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  kind text not null check (kind in ('inicial','renovacion')),
  starts_on date not null,
  ends_on date not null,
  granted_by uuid not null references profiles(id),
  created_at timestamptz not null default now(),
  check (ends_on > starts_on)
);
create index on subscriptions(user_id, ends_on desc);

create table admin_audit_log (
  id bigserial primary key,
  admin_id uuid not null references profiles(id),
  target_user uuid not null references profiles(id),
  action text not null,
  detail jsonb,
  created_at timestamptz not null default now()
);

-- Crear perfil "pendiente" al registrarse
create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles(id, email) values (new.id, new.email);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- ---------- Funciones auxiliares ----------
create function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'admin' and status = 'activo');
$$;

-- Acceso al diario: aprobado + suscripción vigente (el "vencido" se deriva, no se guarda)
create function has_access() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from profiles p
    where p.id = auth.uid() and p.status = 'activo'
      and exists(select 1 from subscriptions s
                 where s.user_id = p.id and current_date between s.starts_on and s.ends_on)
  );
$$;

-- ---------- Tablas del diario ----------
create table accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  name text not null,
  type account_type not null default 'personal',
  broker text,
  currency char(3) not null default 'USD',
  initial_capital numeric(14,2) not null check (initial_capital >= 0),
  daily_loss_value numeric(14,2),
  daily_loss_is_percent boolean not null default false,
  start_date date not null default current_date,
  -- configuración avanzada (todo opcional; el usuario define sus propias reglas)
  profit_target numeric(14,2),
  total_loss_limit numeric(14,2),
  loss_limit_kind loss_limit_kind,
  max_trades_per_day int,
  usual_instruments text[],
  timezone text,
  day_start_time time,
  daily_loss_base daily_loss_base,
  archived boolean not null default false,
  created_at timestamptz not null default now()
);

create table sessions (                    -- una por cuenta y día (v1)
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  account_id uuid not null references accounts(id) on delete cascade,
  session_date date not null,              -- fecha LOCAL del usuario
  state session_state not null default 'operada',
  source result_source not null default 'manual',
  net_result numeric(14,2),                -- solo se usa si source = 'manual'
  trades_count int check (trades_count >= 0),
  emotion text check (emotion in ('tranquilo','confiado','ansioso','frustrado','cansado','euforico')),
  plan plan_followed,
  no_trade_reason text,                    -- si state = 'sin_operar'
  details jsonb not null default '{}',     -- activos, comisiones, preguntas opcionales, notas
  screenshot_path text,                    -- ruta en bucket privado
  closed_at timestamptz,                   -- "Finalizar sesión"
  created_at timestamptz not null default now(),
  unique (account_id, session_date),
  -- una jornada sin operar no lleva resultado; una operada sí (puede ser 0)
  check (state <> 'sin_operar' or net_result is null),
  check (state = 'sin_operar' or source = 'trades' or net_result is not null)
);

create table trades (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  session_id uuid not null references sessions(id) on delete cascade,
  asset text not null,
  side text not null check (side in ('compra','venta')),
  contracts numeric(10,2),
  entry_time timestamptz,
  exit_time timestamptz,
  result numeric(14,2) not null,
  emotion text,
  note text
);

create table preparations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  account_id uuid references accounts(id) on delete cascade,
  prep_date date not null,
  feeling text check (feeling in ('tranquilo','confiado','ansioso','frustrado','cansado','euforico')),
  rest_quality int check (rest_quality between 1 and 5),
  focus_level int check (focus_level between 1 and 5),
  max_risk numeric(14,2),
  intention text,
  created_at timestamptz not null default now()
);

create table cash_movements (              -- depósitos/retiros, fuera del rendimiento
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  account_id uuid not null references accounts(id) on delete cascade,
  kind text not null check (kind in ('deposito','retiro','ajuste')),
  amount numeric(14,2) not null check (amount > 0),
  moved_on date not null default current_date,
  note text
);

create table watchlist_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references profiles(id) on delete cascade,
  symbol text not null,
  label text not null,
  kind text not null check (kind in ('indice','futuro','cripto','materia_prima')),
  contract text,
  position int not null default 0,
  unique (user_id, symbol)
);

-- ---------- Balance calculado (nunca un campo editable) ----------
create view account_balances with (security_invoker = true) as
select a.id as account_id, a.user_id, a.currency, a.initial_capital,
  coalesce(r.trading_result,0) as trading_result,
  coalesce(m.net_movements,0)  as net_movements,
  a.initial_capital + coalesce(r.trading_result,0) + coalesce(m.net_movements,0) as current_balance
from accounts a
left join (
  select s.account_id,
         sum(case when s.source = 'trades'
                  then coalesce((select sum(t.result) from trades t where t.session_id = s.id),0)
                  else coalesce(s.net_result,0) end) as trading_result
  from sessions s group by s.account_id
) r on r.account_id = a.id
left join (
  select account_id,
         sum(case kind when 'retiro' then -amount else amount end) as net_movements
  from cash_movements group by account_id
) m on m.account_id = a.id;

-- ---------- RLS: cada usuario solo ve lo suyo; el admin NO ve el diario ----------
alter table profiles        enable row level security;
alter table subscriptions   enable row level security;
alter table admin_audit_log enable row level security;
alter table accounts        enable row level security;
alter table sessions        enable row level security;
alter table trades          enable row level security;
alter table preparations    enable row level security;
alter table cash_movements  enable row level security;
alter table watchlist_items enable row level security;

-- profiles / subscriptions: lectura propia o admin; SIN políticas de escritura
-- (solo se modifican mediante las funciones admin_* de abajo)
create policy profiles_read on profiles for select using (id = auth.uid() or is_admin());
create policy subs_read     on subscriptions for select using (user_id = auth.uid() or is_admin());
create policy audit_read    on admin_audit_log for select using (is_admin());

-- Tablas del diario: dueño + acceso vigente. No existe ninguna política para admin.
do $$
declare t text;
begin
  foreach t in array array['accounts','sessions','trades','preparations','cash_movements','watchlist_items']
  loop
    execute format(
      'create policy %I on %I for all using (user_id = auth.uid() and has_access())
                                  with check (user_id = auth.uid() and has_access())',
      t || '_owner', t);
  end loop;
end $$;

-- Integridad: la cuenta/sesión referenciada debe ser del mismo usuario
create function check_same_owner() returns trigger language plpgsql as $$
declare owner uuid;
begin
  if tg_table_name = 'trades' then
    select user_id into owner from sessions where id = new.session_id;
  else
    select user_id into owner from accounts where id = new.account_id;
  end if;
  if owner is distinct from new.user_id then
    raise exception 'La referencia pertenece a otro usuario';
  end if;
  return new;
end $$;
create trigger sessions_owner before insert or update on sessions
  for each row execute function check_same_owner();
create trigger trades_owner before insert or update on trades
  for each row execute function check_same_owner();
create trigger cash_owner before insert or update on cash_movements
  for each row execute function check_same_owner();

-- ---------- Funciones de administrador (únicas vías para cambiar estado/suscripción) ----------
create function _require_admin() returns void language plpgsql as $$
begin
  if not is_admin() then raise exception 'No autorizado' using errcode = '42501'; end if;
end $$;

create function _log(target uuid, act text, det jsonb default null) returns void
language sql security definer set search_path = public as $$
  insert into admin_audit_log(admin_id, target_user, action, detail) values (auth.uid(), target, act, det);
$$;

create function admin_approve_user(target uuid) returns void
language plpgsql security definer set search_path = public as $$
declare start_d date := current_date;
begin
  perform _require_admin();
  if not exists(select 1 from profiles where id = target and status = 'pendiente') then
    raise exception 'El usuario no está pendiente';
  end if;
  update profiles set status = 'activo', first_activated_at = coalesce(first_activated_at, now())
   where id = target;
  insert into subscriptions(user_id, kind, starts_on, ends_on, granted_by)
   values (target, 'inicial', start_d, (start_d + interval '1 year')::date, auth.uid());
  perform _log(target, 'aprobar');
end $$;

create function admin_reject_user(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  update profiles set status = 'rechazado' where id = target and status = 'pendiente';
  perform _log(target, 'rechazar');
end $$;

create function admin_suspend_user(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  if target = auth.uid() then raise exception 'No puedes suspenderte a ti mismo'; end if;
  update profiles set status = 'suspendido' where id = target and status = 'activo';
  perform _log(target, 'suspender');
end $$;

create function admin_reactivate_user(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  update profiles set status = 'activo' where id = target and status = 'suspendido';
  perform _log(target, 'reactivar');
end $$;

-- Renovación: si sigue vigente suma 1 año al vencimiento; si ya venció, empieza hoy
create function admin_renew_user(target uuid) returns void
language plpgsql security definer set search_path = public as $$
declare cur_end date; start_d date;
begin
  perform _require_admin();
  if not exists(select 1 from profiles where id = target and status in ('activo','suspendido')) then
    raise exception 'Solo se renuevan usuarios ya aprobados';
  end if;
  select max(ends_on) into cur_end from subscriptions where user_id = target;
  start_d := case when cur_end is not null and cur_end >= current_date then cur_end else current_date end;
  insert into subscriptions(user_id, kind, starts_on, ends_on, granted_by)
   values (target, 'renovacion', start_d, (start_d + interval '1 year')::date, auth.uid());
  perform _log(target, 'renovar', jsonb_build_object('desde', start_d));
end $$;

-- Tabla del panel admin: solo datos de acceso, nunca datos del diario
create function admin_users_overview()
returns table(id uuid, email text, registered_at timestamptz, first_activated_at timestamptz,
              sub_start date, sub_end date, status text, days_left int)
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  return query
  select p.id, p.email, p.registered_at, p.first_activated_at, s.starts_on, s.ends_on,
         case when p.status = 'activo' and (s.ends_on is null or s.ends_on < current_date)
              then 'vencido' else p.status::text end,
         case when s.ends_on is null then null else (s.ends_on - current_date) end
  from profiles p
  left join lateral (select * from subscriptions x where x.user_id = p.id
                     order by x.ends_on desc limit 1) s on true
  order by p.registered_at desc;
end $$;

-- Impedir ejecución pública de las funciones sensibles
revoke all on function admin_approve_user(uuid), admin_reject_user(uuid), admin_suspend_user(uuid),
  admin_reactivate_user(uuid), admin_renew_user(uuid), admin_users_overview(), _log(uuid,text,jsonb)
  from public, anon;
grant execute on function admin_approve_user(uuid), admin_reject_user(uuid), admin_suspend_user(uuid),
  admin_reactivate_user(uuid), admin_renew_user(uuid), admin_users_overview() to authenticated;

-- ---------- Storage: capturas privadas, carpeta = id del usuario ----------
insert into storage.buckets(id, name, public) values ('screenshots','screenshots', false)
  on conflict do nothing;
create policy shots_owner on storage.objects for all to authenticated
  using (bucket_id = 'screenshots' and (storage.foldername(name))[1] = auth.uid()::text and has_access())
  with check (bucket_id = 'screenshots' and (storage.foldername(name))[1] = auth.uid()::text and has_access());

-- ---------- PRIMER ADMINISTRADOR (manual, nunca desde la app) ----------
-- 1) Regístrate normalmente con tu correo y verifícalo.
-- 2) Ejecuta esto UNA vez en el SQL Editor, con tu correo:
--
--   update profiles set role = 'admin', status = 'activo', first_activated_at = now()
--   where email = 'tu-correo@ejemplo.com';
--   insert into subscriptions(user_id, kind, starts_on, ends_on, granted_by)
--   select id, 'inicial', current_date, (current_date + interval '1 year')::date, id
--   from profiles where email = 'tu-correo@ejemplo.com';
