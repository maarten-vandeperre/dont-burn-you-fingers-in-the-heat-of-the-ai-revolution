package org.acme.frontend;

import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.List;

/**
 * Probes services from inside the frontend pod. Requests leave through the frontend's Envoy
 * sidecar with the frontend's mTLS identity, so the results show the AuthorizationPolicies at work.
 */
@ApplicationScoped
public class MeshProbe {

    public record Result(String target, String call, boolean expectedAllowed, String outcome, int status, boolean allowed) {}

    @ConfigProperty(name = "probe.rag", defaultValue = "http://rag-service:8080/api/rag/version")
    String rag;
    @ConfigProperty(name = "probe.orders", defaultValue = "http://orders-service:8080/api/customers")
    String orders;
    @ConfigProperty(name = "probe.projection", defaultValue = "http://projection-service:8080/api/customer-views")
    String projection;
    @ConfigProperty(name = "probe.model-router", defaultValue = "http://model-router:8080/v1/models")
    String modelRouter;
    @ConfigProperty(name = "probe.mongodb-host", defaultValue = "mongodb")
    String mongoHost;

    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3)).build();

    public List<Result> probeAll() {
        return List.of(
                httpProbe("rag-service", rag, true),
                httpProbe("orders-service", orders, true),
                httpProbe("projection-service", projection, true),
                httpProbe("model-router", modelRouter, false),
                tcpProbe("mongodb", mongoHost, 27017, false));
    }

    private Result httpProbe(String target, String url, boolean expected) {
        try {
            HttpResponse<String> r = http.send(HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofSeconds(5)).GET().build(),
                    HttpResponse.BodyHandlers.ofString());
            boolean allowed = r.statusCode() != 403;
            String outcome = r.statusCode() == 403 ? "403 " + r.body().strip() : "HTTP " + r.statusCode();
            return new Result(target, "GET " + url, expected, outcome, r.statusCode(), allowed);
        } catch (IOException | InterruptedException e) {
            return new Result(target, "GET " + url, expected, "connection failed: " + e.getMessage(), 0, false);
        }
    }

    /**
     * MongoDB speaks its own protocol, so this just opens a TCP connection and checks whether the
     * server keeps it open. A denied connection is accepted by the local sidecar and then closed.
     */
    private Result tcpProbe(String target, String host, int port, boolean expected) {
        try (Socket s = new Socket()) {
            s.connect(new InetSocketAddress(host, port), 3000);
            s.setSoTimeout(2000);
            // isMaster handshake is not needed: a reset or EOF within 2 s means the mesh denied us
            s.getOutputStream().write(new byte[]{0});
            int read = -2;
            try {
                read = s.getInputStream().read();
            } catch (java.net.SocketTimeoutException timeout) {
                return new Result(target, "TCP " + host + ":" + port, expected, "connection kept open (allowed)", 0, true);
            }
            boolean allowed = read != -1;
            return new Result(target, "TCP " + host + ":" + port, expected,
                    allowed ? "server answered (allowed)" : "closed by the mesh (RBAC denied)", 0, allowed);
        } catch (IOException e) {
            return new Result(target, "TCP " + host + ":" + port, expected, "denied: " + e.getMessage(), 0, false);
        }
    }
}
