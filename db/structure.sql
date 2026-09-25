SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: append_only_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.append_only_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' AND TG_NARGS > 0
     AND OLD.created_at < now() - TG_ARGV[0]::interval THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION '% is append-only (attempted %)', TG_TABLE_NAME, TG_OP;
END
$$;


--
-- Name: ledger_entries_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ledger_entries_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'ledger_entries is append-only (attempted %)', TG_OP;
END
$$;


--
-- Name: stamp_created_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.stamp_created_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.created_at := now();
  RETURN NEW;
END
$$;


--
-- Name: uuid_generate_v7(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.uuid_generate_v7() RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  unix_ts_ms bytea;
  uuid_bytes bytea;
BEGIN
  unix_ts_ms = substring(int8send(floor(extract(epoch from clock_timestamp()) * 1000)::bigint) from 3);
  uuid_bytes = uuid_send(gen_random_uuid());
  uuid_bytes = overlay(uuid_bytes placing unix_ts_ms from 1 for 6);
  uuid_bytes = set_byte(uuid_bytes, 6, (b'0111' || get_byte(uuid_bytes, 6)::bit(4))::bit(8)::int);
  RETURN encode(uuid_bytes, 'hex')::uuid;
END
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_keys (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    merchant_id uuid NOT NULL,
    livemode boolean NOT NULL,
    name character varying NOT NULL,
    note character varying,
    prefix character varying NOT NULL,
    last4 character varying,
    digest character varying NOT NULL,
    created_by_id uuid,
    last_used_at timestamp(6) without time zone,
    expires_at timestamp(6) without time zone,
    revoked_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_api_keys_mode_matches_prefix CHECK (((livemode AND ((prefix)::text = 'sk_live_'::text)) OR ((NOT livemode) AND ((prefix)::text = 'sk_test_'::text)))),
    CONSTRAINT chk_api_keys_prefix CHECK (((prefix)::text = ANY (ARRAY[('sk_live_'::character varying)::text, ('sk_test_'::character varying)::text])))
);


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    actor_type character varying,
    actor_id uuid,
    actor_label character varying,
    merchant_id uuid,
    on_behalf_of_merchant_id uuid,
    action character varying NOT NULL,
    target_type character varying,
    target_id uuid,
    result character varying NOT NULL,
    ip character varying,
    user_agent character varying,
    request_id character varying,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_audit_events_result CHECK (((result)::text = ANY (ARRAY[('success'::character varying)::text, ('denied'::character varying)::text, ('failure'::character varying)::text])))
);


--
-- Name: captures; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.captures (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    payment_id uuid NOT NULL,
    amount_minor bigint NOT NULL,
    base_captured_minor bigint NOT NULL,
    state character varying DEFAULT 'pending'::character varying NOT NULL,
    failure_code character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_captures_amount_positive CHECK ((amount_minor > 0)),
    CONSTRAINT chk_captures_state CHECK (((state)::text = ANY (ARRAY[('pending'::character varying)::text, ('succeeded'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: fx_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fx_rates (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    base character varying(3) NOT NULL,
    quote character varying(3) NOT NULL,
    rate numeric(18,8) NOT NULL,
    captured_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: idempotency_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.idempotency_keys (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    merchant_id uuid NOT NULL,
    key character varying NOT NULL,
    request_fingerprint character varying NOT NULL,
    response_status integer,
    response_body jsonb,
    locked_at timestamp(6) without time zone,
    expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: inbound_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inbound_events (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    psp_name character varying NOT NULL,
    external_id character varying NOT NULL,
    event_type character varying NOT NULL,
    psp_reference character varying,
    payload jsonb NOT NULL,
    signature_valid boolean NOT NULL,
    psp_timestamp timestamp(6) without time zone,
    received_at timestamp(6) without time zone NOT NULL,
    processed_at timestamp(6) without time zone,
    error character varying,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ledger_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ledger_accounts (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    merchant_id uuid NOT NULL,
    kind character varying NOT NULL,
    currency character varying(3) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_ledger_accounts_kind CHECK (((kind)::text = ANY (ARRAY[('psp_receivable'::character varying)::text, ('merchant_payable'::character varying)::text, ('refunds_reserved'::character varying)::text, ('refunds_paid'::character varying)::text, ('psp_payouts'::character varying)::text, ('psp_fees'::character varying)::text])))
);


--
-- Name: ledger_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ledger_entries (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    transfer_id uuid NOT NULL,
    account_id uuid NOT NULL,
    payment_id uuid,
    refund_id uuid,
    direction character varying NOT NULL,
    amount_minor bigint NOT NULL,
    currency character varying(3) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_ledger_entries_amount_positive CHECK ((amount_minor > 0)),
    CONSTRAINT chk_ledger_entries_direction CHECK (((direction)::text = ANY (ARRAY[('debit'::character varying)::text, ('credit'::character varying)::text])))
);


--
-- Name: merchants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.merchants (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    name character varying NOT NULL,
    api_key_digest character varying NOT NULL,
    webhook_secret character varying NOT NULL,
    webhook_url character varying,
    default_currency character varying(3) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    previous_webhook_secret character varying,
    previous_webhook_secret_expires_at timestamp(6) without time zone,
    livemode boolean DEFAULT true NOT NULL,
    live_merchant_id uuid,
    CONSTRAINT chk_merchants_twin_shape CHECK ((livemode = (live_merchant_id IS NULL)))
);


--
-- Name: outbound_delivery_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outbound_delivery_attempts (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    outbound_event_id uuid NOT NULL,
    attempt_number integer NOT NULL,
    response_status integer,
    error character varying,
    duration_ms integer,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: outbound_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outbound_events (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    merchant_id uuid NOT NULL,
    payment_id uuid,
    event_type character varying NOT NULL,
    payload jsonb NOT NULL,
    state character varying DEFAULT 'pending'::character varying NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp(6) without time zone NOT NULL,
    last_error character varying,
    delivered_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    traceparent character varying,
    CONSTRAINT chk_outbound_events_state CHECK (((state)::text = ANY (ARRAY[('pending'::character varying)::text, ('delivered'::character varying)::text, ('dead'::character varying)::text])))
);


--
-- Name: payment_transitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_transitions (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    payment_id uuid NOT NULL,
    from_state character varying,
    to_state character varying NOT NULL,
    sort_key timestamp(6) without time zone NOT NULL,
    most_recent boolean DEFAULT false NOT NULL,
    source character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    merchant_id uuid NOT NULL,
    state character varying DEFAULT 'pending'::character varying NOT NULL,
    amount_minor bigint NOT NULL,
    currency character varying(3) NOT NULL,
    captured_minor bigint DEFAULT 0 NOT NULL,
    merchant_currency character varying(3) NOT NULL,
    fx_rate numeric(18,8) NOT NULL,
    psp_name character varying NOT NULL,
    psp_reference character varying NOT NULL,
    payment_method_token character varying NOT NULL,
    capture_on_authorize boolean DEFAULT false NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    next_check_at timestamp(6) without time zone,
    check_attempts integer DEFAULT 0 NOT NULL,
    first_sent_at timestamp(6) without time zone,
    CONSTRAINT chk_payments_amount_positive CHECK ((amount_minor > 0)),
    CONSTRAINT chk_payments_captured_non_negative CHECK ((captured_minor >= 0)),
    CONSTRAINT chk_payments_state CHECK (((state)::text = ANY (ARRAY[('pending'::character varying)::text, ('requires_action'::character varying)::text, ('authorized'::character varying)::text, ('unknown'::character varying)::text, ('captured'::character varying)::text, ('canceled'::character varying)::text, ('failed'::character varying)::text, ('part_refunded'::character varying)::text, ('refunded'::character varying)::text])))
);


--
-- Name: psp_calls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.psp_calls (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    psp_name character varying NOT NULL,
    operation character varying NOT NULL,
    psp_reference character varying,
    http_status integer,
    outcome character varying NOT NULL,
    request_redacted jsonb,
    response_redacted jsonb,
    duration_ms integer NOT NULL,
    sent_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_psp_calls_outcome CHECK (((outcome)::text = ANY ((ARRAY['ok'::character varying, 'http_error'::character varying, 'timeout'::character varying, 'unreachable'::character varying])::text[])))
);


--
-- Name: refunds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.refunds (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    payment_id uuid NOT NULL,
    state character varying DEFAULT 'pending'::character varying NOT NULL,
    amount_minor bigint NOT NULL,
    currency character varying(3) NOT NULL,
    psp_reference character varying NOT NULL,
    reason character varying,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_refunds_amount_positive CHECK ((amount_minor > 0)),
    CONSTRAINT chk_refunds_state CHECK (((state)::text = ANY (ARRAY[('pending'::character varying)::text, ('succeeded'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: settlement_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.settlement_lines (
    id uuid DEFAULT public.uuid_generate_v7() NOT NULL,
    psp_name character varying NOT NULL,
    external_id character varying NOT NULL,
    settled_on date NOT NULL,
    kind character varying NOT NULL,
    psp_reference character varying NOT NULL,
    refund_reference character varying,
    payment_id uuid,
    refund_id uuid,
    gross_minor bigint NOT NULL,
    fee_minor bigint NOT NULL,
    net_minor bigint NOT NULL,
    currency character varying(3) NOT NULL,
    booked_at timestamp(6) without time zone NOT NULL,
    status character varying NOT NULL,
    problem character varying,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_settlement_lines_kind CHECK (((kind)::text = ANY (ARRAY[('capture'::character varying)::text, ('refund'::character varying)::text]))),
    CONSTRAINT chk_settlement_lines_status CHECK (((status)::text = ANY (ARRAY[('matched'::character varying)::text, ('unmatched'::character varying)::text, ('mismatch'::character varying)::text])))
);


--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: captures captures_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captures
    ADD CONSTRAINT captures_pkey PRIMARY KEY (id);


--
-- Name: fx_rates fx_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fx_rates
    ADD CONSTRAINT fx_rates_pkey PRIMARY KEY (id);


--
-- Name: idempotency_keys idempotency_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.idempotency_keys
    ADD CONSTRAINT idempotency_keys_pkey PRIMARY KEY (id);


--
-- Name: inbound_events inbound_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbound_events
    ADD CONSTRAINT inbound_events_pkey PRIMARY KEY (id);


--
-- Name: ledger_accounts ledger_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_accounts
    ADD CONSTRAINT ledger_accounts_pkey PRIMARY KEY (id);


--
-- Name: ledger_entries ledger_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT ledger_entries_pkey PRIMARY KEY (id);


--
-- Name: merchants merchants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.merchants
    ADD CONSTRAINT merchants_pkey PRIMARY KEY (id);


--
-- Name: outbound_delivery_attempts outbound_delivery_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_delivery_attempts
    ADD CONSTRAINT outbound_delivery_attempts_pkey PRIMARY KEY (id);


--
-- Name: outbound_events outbound_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_events
    ADD CONSTRAINT outbound_events_pkey PRIMARY KEY (id);


--
-- Name: payment_transitions payment_transitions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_transitions
    ADD CONSTRAINT payment_transitions_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: psp_calls psp_calls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.psp_calls
    ADD CONSTRAINT psp_calls_pkey PRIMARY KEY (id);


--
-- Name: refunds refunds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: settlement_lines settlement_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settlement_lines
    ADD CONSTRAINT settlement_lines_pkey PRIMARY KEY (id);


--
-- Name: idx_captures_one_pending_per_payment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_captures_one_pending_per_payment ON public.captures USING btree (payment_id) WHERE ((state)::text = 'pending'::text);


--
-- Name: idx_delivery_attempts_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_delivery_attempts_unique ON public.outbound_delivery_attempts USING btree (outbound_event_id, attempt_number);


--
-- Name: idx_fx_rates_latest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fx_rates_latest ON public.fx_rates USING btree (base, quote, captured_at DESC);


--
-- Name: idx_idempotency_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_idempotency_expiry ON public.idempotency_keys USING btree (expires_at);


--
-- Name: idx_idempotency_merchant_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_idempotency_merchant_key ON public.idempotency_keys USING btree (merchant_id, key);


--
-- Name: idx_inbound_events_by_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inbound_events_by_ref ON public.inbound_events USING btree (psp_name, psp_reference);


--
-- Name: idx_inbound_events_dedupe; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_inbound_events_dedupe ON public.inbound_events USING btree (psp_name, external_id);


--
-- Name: idx_inbound_events_unprocessed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inbound_events_unprocessed ON public.inbound_events USING btree (received_at) WHERE ((processed_at IS NULL) AND signature_valid);


--
-- Name: idx_ledger_accounts_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ledger_accounts_unique ON public.ledger_accounts USING btree (merchant_id, kind, currency);


--
-- Name: idx_ledger_entries_balance; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ledger_entries_balance ON public.ledger_entries USING btree (account_id, currency);


--
-- Name: idx_ledger_entries_refund_leg; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ledger_entries_refund_leg ON public.ledger_entries USING btree (refund_id, account_id, direction) WHERE (refund_id IS NOT NULL);


--
-- Name: idx_ledger_entries_transfer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ledger_entries_transfer ON public.ledger_entries USING btree (transfer_id);


--
-- Name: idx_merchants_one_test_twin; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_merchants_one_test_twin ON public.merchants USING btree (live_merchant_id);


--
-- Name: idx_outbound_events_list; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_outbound_events_list ON public.outbound_events USING btree (merchant_id, created_at DESC);


--
-- Name: idx_outbound_events_sweeper; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_outbound_events_sweeper ON public.outbound_events USING btree (state, next_attempt_at);


--
-- Name: idx_payments_cursor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payments_cursor ON public.payments USING btree (merchant_id, created_at DESC, id DESC);


--
-- Name: idx_payments_psp_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_payments_psp_ref ON public.payments USING btree (psp_name, psp_reference);


--
-- Name: idx_payments_stuck; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payments_stuck ON public.payments USING btree (state, updated_at);


--
-- Name: idx_refunds_psp_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_refunds_psp_ref ON public.refunds USING btree (psp_reference);


--
-- Name: idx_transitions_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transitions_history ON public.payment_transitions USING btree (payment_id, sort_key);


--
-- Name: idx_transitions_most_recent; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_transitions_most_recent ON public.payment_transitions USING btree (payment_id) WHERE most_recent;


--
-- Name: index_api_keys_on_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_api_keys_on_digest ON public.api_keys USING btree (digest);


--
-- Name: index_api_keys_on_merchant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_api_keys_on_merchant_id ON public.api_keys USING btree (merchant_id);


--
-- Name: index_audit_events_on_action_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_action_and_created_at ON public.audit_events USING btree (action, created_at);


--
-- Name: index_audit_events_on_actor_type_and_actor_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_actor_type_and_actor_id_and_created_at ON public.audit_events USING btree (actor_type, actor_id, created_at);


--
-- Name: index_audit_events_on_merchant_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_merchant_id_and_created_at ON public.audit_events USING btree (merchant_id, created_at);


--
-- Name: index_captures_on_payment_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captures_on_payment_id_and_created_at ON public.captures USING btree (payment_id, created_at);


--
-- Name: index_ledger_entries_on_payment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ledger_entries_on_payment_id ON public.ledger_entries USING btree (payment_id);


--
-- Name: index_merchants_on_api_key_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_merchants_on_api_key_digest ON public.merchants USING btree (api_key_digest);


--
-- Name: index_outbound_events_on_payment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbound_events_on_payment_id ON public.outbound_events USING btree (payment_id);


--
-- Name: index_payments_on_sweeper_due_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_payments_on_sweeper_due_at ON public.payments USING btree (COALESCE(next_check_at, (updated_at + '00:02:00'::interval))) WHERE ((state)::text = ANY (ARRAY[('pending'::character varying)::text, ('unknown'::character varying)::text]));


--
-- Name: index_psp_calls_on_psp_name_and_psp_reference_and_sent_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_psp_calls_on_psp_name_and_psp_reference_and_sent_at ON public.psp_calls USING btree (psp_name, psp_reference, sent_at);


--
-- Name: index_refunds_on_payment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_refunds_on_payment_id ON public.refunds USING btree (payment_id);


--
-- Name: index_settlement_lines_on_payment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_settlement_lines_on_payment_id ON public.settlement_lines USING btree (payment_id);


--
-- Name: index_settlement_lines_on_psp_name_and_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_settlement_lines_on_psp_name_and_external_id ON public.settlement_lines USING btree (psp_name, external_id);


--
-- Name: index_settlement_lines_on_refund_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_settlement_lines_on_refund_id ON public.settlement_lines USING btree (refund_id);


--
-- Name: index_settlement_lines_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_settlement_lines_on_status ON public.settlement_lines USING btree (status) WHERE ((status)::text <> 'matched'::text);


--
-- Name: audit_events trg_audit_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_events_append_only BEFORE DELETE OR UPDATE ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.append_only_guard('12 months');


--
-- Name: audit_events trg_audit_events_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_events_no_truncate BEFORE TRUNCATE ON public.audit_events FOR EACH STATEMENT EXECUTE FUNCTION public.append_only_guard();


--
-- Name: audit_events trg_audit_events_stamp_created_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_events_stamp_created_at BEFORE INSERT ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.stamp_created_at();


--
-- Name: ledger_entries trg_ledger_entries_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ledger_entries_immutable BEFORE DELETE OR UPDATE ON public.ledger_entries FOR EACH ROW EXECUTE FUNCTION public.ledger_entries_immutable();


--
-- Name: psp_calls trg_psp_calls_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_psp_calls_append_only BEFORE DELETE OR UPDATE ON public.psp_calls FOR EACH ROW EXECUTE FUNCTION public.append_only_guard('12 months');


--
-- Name: psp_calls trg_psp_calls_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_psp_calls_no_truncate BEFORE TRUNCATE ON public.psp_calls FOR EACH STATEMENT EXECUTE FUNCTION public.append_only_guard();


--
-- Name: psp_calls trg_psp_calls_stamp_created_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_psp_calls_stamp_created_at BEFORE INSERT ON public.psp_calls FOR EACH ROW EXECUTE FUNCTION public.stamp_created_at();


--
-- Name: refunds fk_rails_25267b0e17; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT fk_rails_25267b0e17 FOREIGN KEY (payment_id) REFERENCES public.payments(id);


--
-- Name: api_keys fk_rails_28b436c585; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT fk_rails_28b436c585 FOREIGN KEY (merchant_id) REFERENCES public.merchants(id);


--
-- Name: settlement_lines fk_rails_2ee98b6baf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settlement_lines
    ADD CONSTRAINT fk_rails_2ee98b6baf FOREIGN KEY (refund_id) REFERENCES public.refunds(id);


--
-- Name: outbound_events fk_rails_36fc4304cc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_events
    ADD CONSTRAINT fk_rails_36fc4304cc FOREIGN KEY (payment_id) REFERENCES public.payments(id);


--
-- Name: ledger_entries fk_rails_41f09c7522; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT fk_rails_41f09c7522 FOREIGN KEY (refund_id) REFERENCES public.refunds(id);


--
-- Name: ledger_entries fk_rails_445b10d4b9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT fk_rails_445b10d4b9 FOREIGN KEY (payment_id) REFERENCES public.payments(id);


--
-- Name: settlement_lines fk_rails_48aaaf96e9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settlement_lines
    ADD CONSTRAINT fk_rails_48aaaf96e9 FOREIGN KEY (payment_id) REFERENCES public.payments(id);


--
-- Name: payment_transitions fk_rails_6a81222e13; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_transitions
    ADD CONSTRAINT fk_rails_6a81222e13 FOREIGN KEY (payment_id) REFERENCES public.payments(id);


--
-- Name: outbound_events fk_rails_7005a6a59c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_events
    ADD CONSTRAINT fk_rails_7005a6a59c FOREIGN KEY (merchant_id) REFERENCES public.merchants(id);


--
-- Name: captures fk_rails_835edaeb47; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captures
    ADD CONSTRAINT fk_rails_835edaeb47 FOREIGN KEY (payment_id) REFERENCES public.payments(id);


--
-- Name: ledger_accounts fk_rails_9581c3f98d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_accounts
    ADD CONSTRAINT fk_rails_9581c3f98d FOREIGN KEY (merchant_id) REFERENCES public.merchants(id);


--
-- Name: ledger_entries fk_rails_95dd992850; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_entries
    ADD CONSTRAINT fk_rails_95dd992850 FOREIGN KEY (account_id) REFERENCES public.ledger_accounts(id);


--
-- Name: merchants fk_rails_a387bf8734; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.merchants
    ADD CONSTRAINT fk_rails_a387bf8734 FOREIGN KEY (live_merchant_id) REFERENCES public.merchants(id);


--
-- Name: idempotency_keys fk_rails_c7488e5117; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.idempotency_keys
    ADD CONSTRAINT fk_rails_c7488e5117 FOREIGN KEY (merchant_id) REFERENCES public.merchants(id);


--
-- Name: payments fk_rails_d6211be8c8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT fk_rails_d6211be8c8 FOREIGN KEY (merchant_id) REFERENCES public.merchants(id);


--
-- Name: outbound_delivery_attempts fk_rails_e95c104a03; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_delivery_attempts
    ADD CONSTRAINT fk_rails_e95c104a03 FOREIGN KEY (outbound_event_id) REFERENCES public.outbound_events(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260925000006'),
('20260925000005'),
('20260925000004'),
('20260925000003'),
('20260925000002'),
('20260925000001'),
('20260924000006'),
('20260924000005'),
('20260924000004'),
('20260924000003'),
('20260924000002'),
('20260924000001'),
('20260923000001'),
('20260922000010'),
('20260922000009'),
('20260922000008'),
('20260922000007'),
('20260922000006'),
('20260922000005'),
('20260922000004'),
('20260922000003'),
('20260922000002'),
('20260922000001');

