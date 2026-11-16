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
