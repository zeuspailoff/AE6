#!/usr/bin/env bash
# comprobar.sh - comprobacion de DNS, directorio e integracion (AE6).
# Uso: bash scripts/comprobar.sh   (opcional: IP_DPL_LAB=172.30.0.10)
set -u
# Git Bash en Windows convertiria /etc/bind/... en una ruta de Windows
export MSYS_NO_PATHCONV=1

IP_DPL_LAB="${IP_DPL_LAB:-172.30.0.10}"
BASE_DN="dc=dpl,dc=local"
USER_DN="${USER_DN:-uid=alumno,ou=usuarios,${BASE_DN}}"
USER_PASSWORD="${USER_PASSWORD:-CAMBIAR_ESTO}"
ZONE_FILE="/etc/bind/db.dpl.local"
FALLOS=0

ok()    { echo "[OK]    $1"; }
fallo() { echo "[FALLO] $1"; FALLOS=$((FALLOS + 1)); }

echo "== DNS =="
docker exec dpl-lab named-checkconf && ok "named-checkconf" || fallo "named-checkconf"
docker exec dpl-lab named-checkzone dpl.local "$ZONE_FILE" | grep -q OK \
  && ok "named-checkzone" || fallo "named-checkzone"
docker exec dpl-lab pgrep -a named >/dev/null && ok "named activo" || fallo "named no activo"

for nombre in www.dpl.local app.dpl.local; do
  ip="$(docker exec dpl-cliente dig +short "@${IP_DPL_LAB}" "$nombre" A)"
  [ -n "$ip" ] && ok "$nombre -> $ip" || fallo "$nombre no resuelve"
done

if docker exec dpl-cliente grep -q dpl.local /etc/hosts; then
  fallo "dpl-cliente tiene entradas dpl.local en /etc/hosts"
else
  ok "sin entradas locales en /etc/hosts"
fi

echo "== Directorio =="
docker exec dpl-lab pgrep -a slapd >/dev/null && ok "slapd activo" || fallo "slapd no activo"
docker exec dpl-lab ldapsearch -x -LLL -b "$BASE_DN" "(uid=alumno)" dn | grep -q "dn:" \
  && ok "usuario alumno en el directorio" || fallo "usuario alumno ausente"
docker exec dpl-cliente ldapwhoami -x -H "ldap://$IP_DPL_LAB" -D "$USER_DN" -w "$USER_PASSWORD" \
  | grep -q "dn:" && ok "bind correcto" || fallo "bind correcto rechazado"
if docker exec dpl-cliente ldapwhoami -x -H "ldap://$IP_DPL_LAB" -D "$USER_DN" -w "incorrecta" >/dev/null 2>&1; then
  fallo "un bind incorrecto no deberia funcionar"
else
  ok "bind incorrecto rechazado"
fi

echo "== Integracion =="
docker exec dpl-cliente curl -s -o /dev/null -w '%{http_code}' http://www.dpl.local \
  | grep -q '^200$' && ok "Web por nombre (200)" || fallo "Web por nombre"
docker exec dpl-cliente curl -s -o /dev/null -w '%{http_code}' http://app.dpl.local:8000/api/mensaje \
  | grep -q '^200$' && ok "aplicacion por nombre (200)" || fallo "aplicacion por nombre"
docker exec dpl-cliente curl -s -o /dev/null -w '%{http_code}' -X POST \
  -d "usuario=alumno&password=${USER_PASSWORD}" http://www.dpl.local/api/login \
  | grep -q '^200$' && ok "login LDAP (200)" || fallo "login LDAP"
docker exec dpl-cliente curl -s -o /dev/null -w '%{http_code}' -X POST \
  -d "usuario=alumno&password=incorrecta" http://www.dpl.local/api/login \
  | grep -q '^401$' && ok "login incorrecto (401)" || fallo "login incorrecto no da 401"

echo
if [ "$FALLOS" -eq 0 ]; then
  echo "Resultado: todas las comprobaciones han pasado."
else
  echo "Resultado: $FALLOS comprobacion(es) fallida(s)."
  exit 1
fi