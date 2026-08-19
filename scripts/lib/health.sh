#!/usr/bin/env bash

http_check() {
  local label="$1"
  local url="$2"

  [[ -n "$url" && "$url" != "None" ]] || die "Missing URL for ${label} health check"

  require_cmd curl
  log "Checking ${label}: ${url}"
  curl -fsS --max-time 20 "$url" >/dev/null || die "Health check failed for ${label}: ${url}"
}

check_backend_health() {
  local backend_base_url
  backend_base_url="$(stack_output BackendBaseUrl)"
  http_check "backend" "${backend_base_url%/}/up"
}

check_frontend_health() {
  local frontend_url
  frontend_url="$(stack_output FrontendApiUrl)"
  http_check "frontend" "$frontend_url"
}
