create type alert_rule_type as enum ('price','import_power','voltage_sag','voltage_swell', 'power_failure');
create type comparison_op as enum ('>','>=','<','<=','==');
create type notification_status as enum ('queued','sent','failed','read');
create type alert_severity as enum ('info','warning','danger');

-- Address
create table address
(
    id          smallserial primary key,
    country     text,
    city        text,
    street      text,
    building    text
);

-- Sites
create table site
(
    id                        smallserial primary key,
    name                      text        not null,
    timezone                  text        not null default 'UTC',
    address_id                bigint references address (id) on delete cascade,
    electricity_provider_name text        not null,
    created_at                timestamptz not null default now()
);

-- Meters
create table meter
(
    id                smallserial primary key,
    site_id           bigint      not null references site (id) on delete cascade, -- when parent is deleted, will this
    name              text        not null,
    manufacturer      text,
    model             text,
    serial_number     text unique,
    phases            smallint    not null check (phases in (1, 3)),
    installation_date date,
    firmware_version  text,
    created_at        timestamptz not null default now()
);

-- Raw time-series readings
create table meter_reading
(
    meter_id               smallint    not null references meter (id) on delete cascade,
    timestamp              timestamptz not null, -- timestamp of the reading
-- Power total on all lines (kW)
    import_kw_total        double precision, -- double precision takes up less space than numeric
    rate_1_import_kw_total double precision,
    rate_2_import_kw_total double precision,
    rate_3_import_kw_total double precision,
    rate_4_import_kw_total double precision,

-- Power instant (kW)
    import_kw_instant      double precision,
    import_kw_l1_instant   double precision,
    import_kw_l2_instant   double precision,
    import_kw_l3_instant   double precision,

-- Export inst and total (kW)
    export_kw_total        double precision,
    export_kw_inst         double precision,

-- Voltage instant (V)
    voltage_v_l1           double precision,
    voltage_v_l2           double precision,
    voltage_v_l3           double precision,

-- Current instant
    current_a_l1           double precision,
    current_a_l2           double precision,
    current_a_l3           double precision,

-- Power quality counters (cumulative)
    sag_count_total        integer,
    sag_count_l1           integer,
    sag_count_l2           integer,
    sag_count_l3           integer,
    swell_count_total      integer,
    swell_count_l1         integer,
    swell_count_l2         integer,
    swell_count_l3         integer,
    power_failures_total   integer,

    created_at             timestamptz not null default now(), -- when the reading was inserted
    primary key (meter_id, timestamp)
);
--     partition by range (timestamp);
create index meter_reading_recent_idx on meter_reading (meter_id, timestamp desc);
--~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- if l2 or l3 readings are inserted, validate that the meter has three phases
create or replace function validate_meter_reading_phase()
    returns trigger
    language plpgsql as
$$
declare
phases_count smallint;
begin
select phases into phases_count from meter where id = new.meter_id;
if phases_count != 3 AND (
        new.import_kw_l2_instant is not null
            OR new.import_kw_l3_instant is not null
            OR new.voltage_v_l2 is not null
            OR new.voltage_v_l3 is not null
            OR new.current_a_l2 is not null
            OR new.current_a_l3 is not null
            OR new.sag_count_l2 is not null
            OR new.sag_count_l3 is not null
            OR new.swell_count_l2 is not null
            OR new.swell_count_l3 is not null
        ) then
        raise exception 'Invalid phase count for meter %', new.meter_id;
end if;
end
$$;
create trigger meter_reading_phase_validator
    before insert or update on meter_reading
                         for each row execute procedure validate_meter_reading_phase();
--~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- TODO: if we are using partitioning, then scheduled function for creating new partition each month is needed
-- create table meter_reading_2025_11 partition of meter_reading
--     for values from ('2025-11-01') to ('2025-12-01');
-- create table meter_reading_2025_12 partition of meter_reading
--     for values from ('2025-12-01') to ('2026-01-01');

-- Price catalogs
create table price_provider
(
    id            smallserial primary key,
    name          text        not null,
    created_at    timestamptz not null default now()
);

create table price_area
(
    id            bigserial primary key,
    provider_id   bigint  not null references price_provider (id) on delete cascade,
    timezone      text    not null default 'UTC',
    code          text    not null,
    currency_code char(3) not null default 'EUR',
    name          text    not null,
    unique (provider_id, code)
);

-- 15-minute prices
create table electricity_price
(
    id            bigserial     primary key,
    area_id       bigint        not null references price_area (id) on delete cascade,
    valid_from    timestamptz   not null,
    valid_to      timestamptz   not null,
    price_per_kwh numeric(6, 4) not null, -- xx.xxxx
    source        jsonb,                  -- raw API response for traceability
    created_at    timestamptz    not null default now(),
    check (valid_to > valid_from),
    check ((valid_to - valid_from) = interval '15 minutes')
    );
create unique index electricity_price_uq on electricity_price (area_id, valid_from);

-- Alert rules
-- Scope: a rule can be tied to a site, a meter, or a price provider/area (for price rules).
-- The server will evaluate Rules on a regular schedule.
-- validations for inserting here:
--  - area_id must be present if rule_type is price
--  - meter_id must be present if rule_type is import_power, export_power, voltage_sag or voltage_swell
--  - comparison must be present if threshold_value is present
--  - a lot more checks
create table alert_rule
(
    id              smallserial     primary key,
    enabled         boolean         not null default false,
    site_id         bigint          references site (id) on delete cascade,
    meter_id        bigint          references meter (id) on delete cascade,
    area_id         bigint          references price_area (id) on delete cascade,
    rule_type       alert_rule_type not null,
    comparison      comparison_op,
    threshold_value numeric(14, 6),
--     phase           smallint,       -- for per-phase rules (1..3) maybe too much of an overkill
    severity        alert_severity  not null default 'info',
    title           text,
    created_at      timestamptz     not null default now()
);

create table alert_rule_active_hours
(
    id            bigserial primary key,
    alert_rule_id bigint      not null references alert_rule (id) on delete cascade,
    start_minute  smallint    not null,
    end_minute    smallint    not null,
    created_at    timestamptz not null default now(),

    check (start_minute >= 0 and start_minute < 1440),
    check (end_minute > 0 and end_minute <= 1440),
    check (start_minute < end_minute)
);

--~~~~~~~~~~ALERT TRIGGER START~~~~~~~~~~~~~~~~
create or replace function trg_enforce_no_overlap_active_hours()
    returns trigger
    language plpgsql
as
$$
begin
    if exists (select 1
               from alert_rule_active_hours existing_rule
               where
                 existing_rule.alert_rule_id = NEW.alert_rule_id -- same rule
                 and (TG_OP = 'INSERT' or existing_rule.id <> NEW.id) -- new row OR existing row is being updated
                 and not ( --  new start later than existing end OR new end earlier than existing start
                     NEW.end_minute <= existing_rule.start_minute
                     or NEW.start_minute >= existing_rule.end_minute)
                )
        then
        raise exception 'Overlapping active hours for rule %: [%..%) conflicts with an existing row',
            NEW.alert_rule_id, NEW.start_minute, NEW.end_minute;
end if;
return NEW;
end;
$$;
create trigger alert_rule_active_hours_overlap_validator
    before insert on alert_rule_active_hours
    for each row execute procedure trg_enforce_no_overlap_active_hours();
--~~~~~~~~~~ALERT TRIGGER END~~~~~~~~~~~~~~~~

create index if not exists alert_rule_active_hours_rule_idx -- for quicker time overlap validation
    on alert_rule_active_hours (alert_rule_id, start_minute, end_minute);

-- When a rule fires
create table alert_event
(
    id             bigserial    primary key,
    rule_id        bigint       not null references alert_rule (id) on delete cascade,
    occurred_at    timestamptz  not null,
    observed_value numeric(14, 6),
    created_at     timestamptz  not null default now()
);

-- Notification delivery log
create table notification
(
    id       bigserial primary key,
    event_id bigint              not null references alert_event (id) on delete cascade,
    status   notification_status not null default 'queued',
    sent_at  timestamptz,
    details  text                          -- error or provider response
);

-- TODO: add a trigger number of voltage sags or swells increases
