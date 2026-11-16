# Informe de diagnostico AE6

Entorno: dpl-lab 172.30.0.10 (BIND9 y slapd), dpl-cliente 172.30.0.20, nginx 172.30.0.30, app 172.30.0.31. Cada fallo se provoco a proposito y se resolvio con los comandos mostrados.

## Fallo 1: DNS

### Como se provoco

Se cambio en la zona el registro A de www a una IP inexistente (172.30.0.99) y se recargo named:

```
$ docker exec dpl-lab sed -i s/172.30.0.30/172.30.0.99/; s/2026111601/2026111602/ /etc/bind/db.dpl.local
[codigo de salida: 0]
```

```
$ docker exec dpl-lab pkill -HUP named
[codigo de salida: 0]
```

- **Sintoma observado:** www.dpl.local no responde por nombre aunque nginx esta en marcha. dig devuelve una IP y curl no conecta.

```
$ docker exec dpl-cliente dig +short @172.30.0.10 www.dpl.local A
172.30.0.99
[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -sS --max-time 3 -I http://www.dpl.local
curl: (28) Connection timed out after 3002 milliseconds
[codigo de salida: 28]
```

- **Causa:** el registro A de www apunta a 172.30.0.99, una IP donde no hay ningun servicio. La zona es sintacticamente valida, por eso named-checkzone no lo detecta; el error esta en los datos.

- **Comprobacion:** se compara la IP del registro con la IP real del contenedor nginx:

```
$ docker exec dpl-lab named-checkzone dpl.local /etc/bind/db.dpl.local
zone dpl.local/IN: loaded serial 2026111602
OK
[codigo de salida: 0]
```

```
$ docker exec dpl-lab grep -n www /etc/bind/db.dpl.local
12:www IN  A   172.30.0.99
[codigo de salida: 0]
```

```
$ docker inspect -f {{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}} dpl-ae4-nginx-1
/dpl-ae4-nginx-1 172.18.0.5 172.30.0.30 
[codigo de salida: 0]
```

- **Correccion aplicada:** se restaura la IP correcta y se sube el serial a 2026111603 (siempre creciente, para que cualquier servidor secundario detecte el cambio). El fichero dns/dpl.local.db del repositorio queda con el serial final.

```
$ grep -n -E SOA|Serial|www dns/dpl.local.db
2:@   IN  SOA ns1.dpl.local. admin.dpl.local. (
3:            2026111603  ; Serial (AAAAMMDDNN)
12:www IN  A   172.30.0.30
[codigo de salida: 0]
```

```
$ docker cp dns/dpl.local.db dpl-lab:/etc/bind/db.dpl.local
[codigo de salida: 0]
```

```
$ docker exec dpl-lab named-checkzone dpl.local /etc/bind/db.dpl.local
zone dpl.local/IN: loaded serial 2026111603
OK
[codigo de salida: 0]
```

```
$ docker exec dpl-lab pkill -HUP named
[codigo de salida: 0]
```

- **Verificacion final:**

```
$ docker exec dpl-cliente dig +short @172.30.0.10 www.dpl.local A
172.30.0.30
[codigo de salida: 0]
```

```
$ docker exec dpl-cliente dig +short @172.30.0.10 dpl.local SOA
ns1.dpl.local. admin.dpl.local. 2026111603 604800 86400 2419200 604800
[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -sS --max-time 3 -I http://www.dpl.local
HTTP/1.1 200 OK
Server: nginx/1.27.5
Date: Mon, 16 Nov 2026 23:30:44 GMT
Content-Type: text/html; charset=utf-8
Connection: keep-alive

[codigo de salida: 0]
```

## Fallo 2: Puerto

### Como se provoco

Se cambio en nginx/default.conf el proxy_pass de http://app:8000 a http://app:8080 y se reinicio nginx:

```
$ cambia_puerto 8000 8080
6:        proxy_pass http://app:8080;
[codigo de salida: 0]
```

```
$ docker restart dpl-ae4-nginx-1
dpl-ae4-nginx-1
[codigo de salida: 0]
```

- **Sintoma observado:** www.dpl.local responde, pero con error 502 Bad Gateway. El DNS resuelve bien y la aplicacion sigue sana en su puerto.

```
$ docker exec dpl-cliente dig +short @172.30.0.10 www.dpl.local A
172.30.0.30
[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -sS --max-time 5 -I http://www.dpl.local
HTTP/1.1 502 Bad Gateway
Server: nginx/1.27.5
Date: Mon, 16 Nov 2026 23:32:20 GMT
Content-Type: text/html
Content-Length: 157
Connection: keep-alive

[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -sS -o /dev/null -w HTTP %{http_code}\n http://app.dpl.local:8000/healthz
HTTP 200
[codigo de salida: 0]
```

- **Causa:** nginx reenvia al puerto 8080 del contenedor app, pero Gunicorn escucha en el 8000 (CMD del Dockerfile: --bind 0.0.0.0:8000). Nadie escucha en el 8080 y la conexion es rechazada.

- **Comprobacion:** el log de nginx muestra el rechazo de conexion contra el upstream y la configuracion activa muestra el puerto equivocado:

```
$ docker logs --tail 8 dpl-ae4-nginx-1
2026/11/16 23:32:14 [notice] 1#1: start worker process 27
2026/11/16 23:32:14 [notice] 1#1: start worker process 28
2026/11/16 23:32:14 [notice] 1#1: start worker process 29
2026/11/16 23:32:14 [notice] 1#1: start worker process 30
2026/11/16 23:32:14 [notice] 1#1: start worker process 31
2026/11/16 23:32:14 [notice] 1#1: start worker process 32
2026/11/16 23:32:20 [error] 21#21: *1 connect() failed (111: Connection refused) while connecting to upstream, client: 172.30.0.20, server: _, request: "HEAD / HTTP/1.1", upstream: "http://172.18.0.4:8080/", host: "www.dpl.local"
172.30.0.20 - - [16/Nov/2026:23:32:20 +0000] "HEAD / HTTP/1.1" 502 0 "-" "curl/8.5.0" "-"
[codigo de salida: 0]
```

```
$ docker exec dpl-ae4-nginx-1 cat /etc/nginx/conf.d/default.conf
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://app:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}[codigo de salida: 0]
```

- **Correccion aplicada:** se restaura proxy_pass http://app:8000 y se reinicia nginx.

```
$ cambia_puerto 8080 8000
6:        proxy_pass http://app:8000;
[codigo de salida: 0]
```

```
$ docker restart dpl-ae4-nginx-1
dpl-ae4-nginx-1
[codigo de salida: 0]
```

- **Verificacion final:**

```
$ docker exec dpl-cliente curl -sS --max-time 5 -I http://www.dpl.local
HTTP/1.1 200 OK
Server: nginx/1.27.5
Date: Mon, 16 Nov 2026 23:32:29 GMT
Content-Type: text/html; charset=utf-8
Connection: keep-alive

[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -s -X POST -d usuario=alumno&password=CAMBIAR_ESTO http://www.dpl.local/api/login
{"autenticado": true, "usuario": "alumno", "perfil": {"cn": "Alumno DPL", "mail": "alumno@dpl.local"}}[codigo de salida: 0]
```

## Fallo 3: Servidor Web

### Como se provoco

Se introdujo una errata en el server block de nginx (proxy_pass escrito como proxy_pas) y se reinicio el contenedor:

```
$ cambia_conf proxy_pass proxy_pas
6:        proxy_pas http://app:8000;
[codigo de salida: 0]
```

```
$ docker restart dpl-ae4-nginx-1
dpl-ae4-nginx-1
[codigo de salida: 0]
```

- **Sintoma observado:** www.dpl.local no responde en el puerto 80. El DNS resuelve bien, pero curl falla; la aplicacion, en cambio, responde directamente en su puerto 8000.

```
$ docker exec dpl-cliente dig +short @172.30.0.10 www.dpl.local A
172.30.0.30
[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -sS --max-time 5 -I http://www.dpl.local
curl: (28) Connection timed out after 5002 milliseconds
[codigo de salida: 28]
```

```
$ docker exec dpl-cliente curl -sS -o /dev/null -w HTTP %{http_code}\n http://app.dpl.local:8000/healthz
HTTP 200
[codigo de salida: 0]
```

- **Causa:** el server block tiene una directiva desconocida (proxy_pas), nginx no supera la validacion de configuracion y no llega a arrancar; Docker lo reinicia en bucle.

- **Comprobacion:** el estado del contenedor y el log de nginx senalan la linea exacta:

```
$ docker ps -a --filter name=dpl-ae4-nginx --format table {{.Names}}\t{{.Status}}
NAMES             STATUS
dpl-ae4-nginx-1   Restarting (1) 5 seconds ago
[codigo de salida: 0]
```

```
$ docker logs --tail 6 dpl-ae4-nginx-1
/docker-entrypoint.sh: Sourcing /docker-entrypoint.d/15-local-resolvers.envsh
/docker-entrypoint.sh: Launching /docker-entrypoint.d/20-envsubst-on-templates.sh
/docker-entrypoint.sh: Launching /docker-entrypoint.d/30-tune-worker-processes.sh
/docker-entrypoint.sh: Configuration complete; ready for start up
2026/11/16 23:37:06 [emerg] 1#1: unknown directive "proxy_pas" in /etc/nginx/conf.d/default.conf:6
nginx: [emerg] unknown directive "proxy_pas" in /etc/nginx/conf.d/default.conf:6
[codigo de salida: 0]
```

- **Correccion aplicada:** se corrige la directiva a proxy_pass, se valida la sintaxis con una instancia temporal y se reinicia nginx.

```
$ cambia_conf proxy_pas  proxy_pass 
6:        proxy_pass http://app:8000;
[codigo de salida: 0]
```

```
$ docker run --rm -v D:/Fp informatica/2 curso/trabajos AE/dpl-ae4/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro --add-host app:127.0.0.1 nginx:1.27-alpine nginx -t
/docker-entrypoint.sh: /docker-entrypoint.d/ is not empty, will attempt to perform configuration
/docker-entrypoint.sh: Looking for shell scripts in /docker-entrypoint.d/
/docker-entrypoint.sh: Launching /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh
10-listen-on-ipv6-by-default.sh: info: can not modify /etc/nginx/conf.d/default.conf (read-only file system?)
/docker-entrypoint.sh: Sourcing /docker-entrypoint.d/15-local-resolvers.envsh
/docker-entrypoint.sh: Launching /docker-entrypoint.d/20-envsubst-on-templates.sh
/docker-entrypoint.sh: Launching /docker-entrypoint.d/30-tune-worker-processes.sh
/docker-entrypoint.sh: Configuration complete; ready for start up
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
[codigo de salida: 0]
```

```
$ docker restart dpl-ae4-nginx-1
dpl-ae4-nginx-1
[codigo de salida: 0]
```

- **Verificacion final:**

```
$ docker ps --filter name=dpl-ae4-nginx --format table {{.Names}}\t{{.Status}}
NAMES             STATUS
dpl-ae4-nginx-1   Up 6 seconds
[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -sS --max-time 5 -I http://www.dpl.local
HTTP/1.1 200 OK
Server: nginx/1.27.5
Date: Mon, 16 Nov 2026 23:37:20 GMT
Content-Type: text/html; charset=utf-8
Connection: keep-alive

[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -s -X POST -d usuario=alumno&password=CAMBIAR_ESTO http://www.dpl.local/api/login
{"autenticado": true, "usuario": "alumno", "perfil": {"cn": "Alumno DPL", "mail": "alumno@dpl.local"}}[codigo de salida: 0]
```


## Fallo 4: Servidor de aplicaciones

### Como se provoco

Se detuvo el contenedor de la aplicacion (Django/Gunicorn). Al pararlo a mano, la politica restart: unless-stopped no lo vuelve a levantar:

```
$ docker stop dpl-ae4-app-1
dpl-ae4-app-1
[codigo de salida: 0]
```

- **Sintoma observado:** www.dpl.local sigue resolviendo, pero la web no sirve nada: la peticion HEAD a la raiz agota el tiempo (curl 28) y el login a traves de nginx devuelve 502 Bad Gateway. La aplicacion tampoco responde directamente en su puerto 8000 (timeout, HTTP 000).

```
$ docker exec dpl-cliente dig +short @172.30.0.10 www.dpl.local A
172.30.0.30
[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -sS --max-time 5 -I http://www.dpl.local
curl: (28) Operation timed out after 5002 milliseconds with 0 bytes received
[codigo de salida: 28]
```

```
$ docker exec dpl-cliente curl -sS --max-time 5 -o /dev/null -w HTTP %{http_code}\n http://app.dpl.local:8000/healthz
curl: (28) Connection timed out after 5002 milliseconds
HTTP 000
[codigo de salida: 28]
```

```
$ docker exec dpl-cliente curl -sS --max-time 5 -o /dev/null -w HTTP %{http_code}\n -X POST -d usuario=alumno&password=CAMBIAR_ESTO http://www.dpl.local/api/login
HTTP 502
[codigo de salida: 0]
```

- **Causa:** el contenedor dpl-ae4-app-1 esta parado (Exited). nginx esta sano, pero su upstream no existe; por eso nginx no consigue conectar con ella (timeouts y 502) y la aplicacion no escucha en el puerto 8000. Al pararse el contenedor su IP deja de existir en la red, de modo que la conexion no se rechaza al instante sino que queda esperando.

- **Comprobacion:** estado de los contenedores, log de la aplicacion y log de nginx:

```
$ docker ps -a --filter name=dpl-ae4 --format table {{.Names}}\t{{.Status}}
NAMES               STATUS
dpl-ae4-app-1       Exited (0) 19 seconds ago
dpl-ae4-nginx-1     Up 5 minutes
dpl-ae4-pgadmin-1   Up 25 minutes
dpl-ae4-db-1        Up 25 minutes (healthy)
[codigo de salida: 0]
```

```
$ docker inspect -f {{.State.Status}} exit={{.State.ExitCode}} dpl-ae4-app-1
exited exit=0
[codigo de salida: 0]
```

```
$ docker logs --tail 4 dpl-ae4-app-1
[2026-11-16 23:46:41 +0000] [1] [INFO] Handling signal: term
[2026-11-17 00:46:41 +0100] [7] [INFO] Worker exiting (pid: 7)
[2026-11-17 00:46:41 +0100] [8] [INFO] Worker exiting (pid: 8)
[2026-11-16 23:46:41 +0000] [1] [INFO] Shutting down: Master
[codigo de salida: 0]
```

```
$ docker logs --tail 3 dpl-ae4-nginx-1
172.30.0.20 - - [16/Nov/2026:23:46:51 +0000] "HEAD / HTTP/1.1" 499 0 "-" "curl/8.5.0" "-"
2026/11/16 23:47:00 [error] 25#25: *7 connect() failed (113: Host is unreachable) while connecting to upstream, client: 172.30.0.20, server: _, request: "POST /api/login HTTP/1.1", upstream: "http://172.18.0.4:8000/api/login", host: "www.dpl.local"
172.30.0.20 - - [16/Nov/2026:23:47:00 +0000] "POST /api/login HTTP/1.1" 502 157 "-" "curl/8.5.0" "-"
[codigo de salida: 0]
```

- **Correccion aplicada:** se arranca la aplicacion, se espera a su healthcheck y se reinicia nginx para que vuelva a resolver el nombre del upstream.

```
$ docker start dpl-ae4-app-1
dpl-ae4-app-1
[codigo de salida: 0]
```

```
$ docker ps --filter name=dpl-ae4-app --format table {{.Names}}\t{{.Status}}
NAMES           STATUS
dpl-ae4-app-1   Up 15 seconds (healthy)
[codigo de salida: 0]
```

```
$ docker restart dpl-ae4-nginx-1
dpl-ae4-nginx-1
[codigo de salida: 0]
```

- **Verificacion final:**

```
$ docker exec dpl-cliente curl -sS --max-time 5 -o /dev/null -w HTTP %{http_code}\n http://app.dpl.local:8000/healthz
HTTP 200
[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -sS --max-time 5 -I http://www.dpl.local
HTTP/1.1 200 OK
Server: nginx/1.27.5
Date: Mon, 16 Nov 2026 23:47:25 GMT
Content-Type: text/html; charset=utf-8
Connection: keep-alive

[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -s -X POST -d usuario=alumno&password=CAMBIAR_ESTO http://www.dpl.local/api/login
{"autenticado": true, "usuario": "alumno", "perfil": {"cn": "Alumno DPL", "mail": "alumno@dpl.local"}}[codigo de salida: 0]
```

## Fallo 5: Autenticacion

### Como se provoco

Se recreo el contenedor de la aplicacion con una LDAP_BASE_DN erronea (ou=personas en lugar de ou=usuarios) y se reinicio nginx para que resuelva de nuevo el nombre del upstream:

```
$ en_ae4 env LDAP_BASE_DN=ou=personas,dc=dpl,dc=local docker compose -f compose.yml -f compose.ae6.yml up -d app
 Container dpl-ae4-db-1 Running 
 Container dpl-ae4-app-1 Recreate 
 Container dpl-ae4-app-1 Recreated 
 Container dpl-ae4-db-1 Waiting 
 Container dpl-ae4-db-1 Healthy 
 Container dpl-ae4-app-1 Starting 
 Container dpl-ae4-app-1 Started 
[codigo de salida: 0]
```

```
$ docker restart dpl-ae4-nginx-1
dpl-ae4-nginx-1
[codigo de salida: 0]
```

- **Sintoma observado:** la web y la aplicacion responden con normalidad, pero el login con credenciales correctas devuelve 401.

```
$ docker exec dpl-cliente curl -sS --max-time 5 -o /dev/null -w HTTP %{http_code}\n http://www.dpl.local
HTTP 200
[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -sS --max-time 5 -o /dev/null -w HTTP %{http_code}\n http://app.dpl.local:8000/healthz
HTTP 200
[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -s -w \nHTTP %{http_code}\n -X POST -d usuario=alumno&password=CAMBIAR_ESTO http://www.dpl.local/api/login
{"autenticado": false, "usuario": "alumno", "detalle": "automatic bind not successful - invalidCredentials"}
HTTP 401
[codigo de salida: 0]
```

- **Causa:** la variable LDAP_BASE_DN de la aplicacion apunta a una unidad organizativa que no existe, asi que el DN con el que la vista intenta el bind (uid=alumno,ou=personas,...) no existe en el directorio. El directorio, el DNS, nginx y Gunicorn estan sanos.

- **Comprobacion:** el directorio acepta las mismas credenciales con el DN correcto, y las variables LDAP_* del contenedor muestran la base equivocada:

```
$ docker exec dpl-cliente ldapwhoami -x -H ldap://172.30.0.10 -D uid=alumno,ou=usuarios,dc=dpl,dc=local -w CAMBIAR_ESTO
dn:uid=alumno,ou=usuarios,dc=dpl,dc=local
[codigo de salida: 0]
```

```
$ docker exec dpl-ae4-app-1 printenv LDAP_HOST LDAP_BASE_DN LDAP_USER_FILTER
ldap://172.30.0.10
ou=personas,dc=dpl,dc=local
(uid=%s)
[codigo de salida: 0]
```

- **Correccion aplicada:** se recrea la aplicacion con los valores por defecto del compose (LDAP_BASE_DN=ou=usuarios,dc=dpl,dc=local) y se reinicia nginx.

```
$ en_ae4 docker compose -f compose.yml -f compose.ae6.yml up -d app
 Container dpl-ae4-db-1 Running 
 Container dpl-ae4-app-1 Recreate 
 Container dpl-ae4-app-1 Recreated 
 Container dpl-ae4-db-1 Waiting 
 Container dpl-ae4-db-1 Healthy 
 Container dpl-ae4-app-1 Starting 
 Container dpl-ae4-app-1 Started 
[codigo de salida: 0]
```

```
$ docker restart dpl-ae4-nginx-1
dpl-ae4-nginx-1
[codigo de salida: 0]
```

- **Verificacion final:**

```
$ docker exec dpl-ae4-app-1 printenv LDAP_BASE_DN
ou=usuarios,dc=dpl,dc=local
[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -s -X POST -d usuario=alumno&password=CAMBIAR_ESTO http://www.dpl.local/api/login
{"autenticado": true, "usuario": "alumno", "perfil": {"cn": "Alumno DPL", "mail": "alumno@dpl.local"}}[codigo de salida: 0]
```

```
$ docker exec dpl-cliente curl -s -o /dev/null -w HTTP %{http_code}\n -X POST -d usuario=alumno&password=incorrecta http://www.dpl.local/api/login
HTTP 401
[codigo de salida: 0]
```

