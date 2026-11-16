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
