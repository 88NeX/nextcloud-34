FROM ghcr.io/euro-office/documentserver:latest

# Патч 1 — entrypoint.sh:
#   - openssl genrsa -traditional (PKCS#1) вместо genpkey (PKCS#8)
#     Node.js crypto в Euro-Office не поддерживает PKCS#8 → DECODER::unsupported
#   - cat вместо awk для WOPI_PRIVATE_KEY_DATA — реальные переносы строк в PEM
#     Literal \n в строке так же вызывает DECODER::unsupported
#   - Миграция существующих PKCS#8 ключей → PKCS#1 при первом старте
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Патч 2 — supervisord:
#   NODE_TLS_REJECT_UNAUTHORIZED=0 для docservice и converter.
#   Node.js не читает системный CA store → mkcert/самоподписанные сертификаты
#   вызывают CERT_INVALID при HTTPS-запросах к Nextcloud.
RUN for conf in /etc/supervisor/conf.d/ds-docservice.conf \
                /etc/supervisor/conf.d/ds-converter.conf; do \
      [ -f "$conf" ] || continue; \
      grep -q 'NODE_TLS_REJECT_UNAUTHORIZED' "$conf" && continue; \
      grep -q '^environment=' "$conf" \
        && sed -i 's/^\(environment=.*\)$/\1,NODE_TLS_REJECT_UNAUTHORIZED="0"/' "$conf" \
        || sed -i '/^\[program:/a environment=NODE_TLS_REJECT_UNAUTHORIZED="0"' "$conf"; \
    done
