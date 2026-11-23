# TLS en los servicios expuestos (HU-35, E2.6)

Todo lo que CircleGuard expone pasa por el Ingress de Traefik (k3s): la app web, la API
(`/api/v1/...`), Grafana (`/grafana`) y Jaeger (`/jaeger`). Con esta configuración Traefik sirve
**HTTPS en el puerto 443** con un certificado emitido y renovado por **cert-manager**.

## 1. Decisión y justificación

| Opción | Por qué se descartó o eligió |
|---|---|
| Let's Encrypt (CA pública) | Necesita un **dominio público** y que sus servidores lleguen al puerto 80. Los ambientes solo tienen IPs, que cambian al apagar y prender las instancias, y los security groups solo admiten al host de Jenkins y a las IPs del equipo. La validación ACME no es posible. |
| Certificado autofirmado suelto | Cada cliente tendría que aceptar una excepción (`curl -k`, aviso del navegador): cifra pero **no se puede verificar**, y nadie lo renueva. |
| **CA interna con cert-manager** ✅ | cert-manager crea una **CA propia de CircleGuard** y con ella firma el certificado del Ingress (con las IPs de cada nodo). Quien importe el certificado de la CA verifica la conexión sin excepciones. cert-manager **renueva** los certificados antes de que venzan. Es el mismo modelo que se usa en redes internas sin dominio público. |

Si el proyecto tuviera un dominio, basta con añadir un `ClusterIssuer` ACME (Let's Encrypt) y
cambiar el `issuerRef` del certificado; el resto (TLSStore, Ingress) no cambia.

## 2. Piezas

```text
selfsigned-bootstrap ──firma──► circleguard-root-ca (CA, 2 años, Secret en cert-manager)
                                         │
circleguard-ca (ClusterIssuer) ◄─────────┘
        │ firma
        ▼
circleguard-ingress-tls (90 días, IPs del nodo) ──► TLSStore "default" de Traefik ──► :443
```

| Archivo | Qué contiene |
|---|---|
| `infra/k8s/cert-manager/` | cert-manager v1.16.2 (release oficial, versión fija). |
| `infra/k8s/tls/base/issuers.yaml` | Emisor de arranque, certificado de la CA y `ClusterIssuer` `circleguard-ca`. |
| `infra/k8s/tls/base/ingress-certificate.yaml` | Certificado del Ingress (ECDSA P-256, 90 días, se renueva 15 días antes). |
| `infra/k8s/tls/base/traefik-tlsstore.yaml` | Certificado por defecto de Traefik: aplica a **todos** los Ingress sin modificarlos. |
| `infra/k8s/tls/overlays/<env>/` | IPs de cada ambiente en el certificado (dev: `10.20.2.113` y la IP pública actual; stage: `10.20.3.109`; prod: `10.20.4.229`). |

La clave privada de la CA vive solo en el Secret `circleguard-root-ca` del namespace
`cert-manager`; nunca se exporta ni está en el repositorio. Lo que se distribuye es el
**certificado** público de la CA (`ca.crt`).

## 3. Instalación (una vez por clúster, contexto de administrador)

```bash
# 1. cert-manager
sudo k3s kubectl apply -k infra/k8s/cert-manager
sudo k3s kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s

# 2. CA, certificado y Traefik (cambiar dev por stage/prod)
sudo k3s kubectl apply -k infra/k8s/tls/overlays/dev
sudo k3s kubectl get certificate -A          # READY debe ser True en circleguard-root-ca y circleguard-ingress
```

En el security group del nodo debe estar abierto el **443** para quienes usan el ambiente (hoy
lo está para el host de Jenkins; para las IPs del equipo hay que añadirlo).

## 4. Verificación (TLS verificable)

```bash
# Exportar el certificado de la CA (solo la parte pública)
sudo k3s kubectl get secret circleguard-root-ca -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > circleguard-ca.crt

# Conexión verificada contra la CA, sin -k
curl --cacert circleguard-ca.crt -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' https://10.20.2.113/
# esperado: 200 0   (ssl_verify_result 0 = cadena válida)

# Detalle del certificado servido
openssl s_client -connect 10.20.2.113:443 -CAfile circleguard-ca.crt </dev/null 2>/dev/null \
  | grep -E "subject=|issuer=|Verify return code"
# esperado: issuer=O = CircleGuard, CN = CircleGuard Root CA   y   Verify return code: 0 (ok)

# Sin la CA, la verificación falla (demuestra que el certificado no es de una CA pública)
curl -sS https://10.20.2.113/ -o /dev/null || echo "sin la CA: no confiable, como se espera"
```

**En el navegador:** importar `circleguard-ca.crt` como autoridad de confianza (Chrome/Edge:
*Configuración → Privacidad y seguridad → Seguridad → Gestionar certificados → Autoridades*;
macOS: Acceso a Llaveros, marcar *Confiar siempre*). Después `https://<IP>/` abre con el candado y
sin advertencias.

## 5. Renovación y cambios de IP

- cert-manager renueva el certificado del Ingress 15 días antes de vencer y la CA 30 días antes.
  Estado: `kubectl get certificate -A` y `kubectl describe certificate circleguard-ingress -n kube-system`.
- La IP pública de dev cambia cuando la instancia se apaga y se prende. Actualizarla en
  `infra/k8s/tls/overlays/dev/kustomization.yaml` y volver a aplicar: cert-manager emite el
  certificado nuevo y Traefik lo toma solo.

## 6. Alcance actual

- HTTP (puerto 80) **sigue disponible** a propósito: el pipeline (verificación, smoke, E2E y ZAP)
  usa `http://10.20.2.113`. El siguiente paso es pasar esas URLs a `https://` con la CA y activar
  la redirección HTTP → HTTPS en Traefik.
- El tráfico entre pods dentro del clúster no va cifrado (no hay service mesh). mTLS entre
  servicios (Istio/Linkerd) es una bonificación opcional del proyecto.
