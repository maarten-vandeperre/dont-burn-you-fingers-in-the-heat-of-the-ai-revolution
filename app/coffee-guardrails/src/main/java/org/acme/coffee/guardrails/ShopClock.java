package org.acme.coffee.guardrails;

import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.time.LocalTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;

/**
 * The shop's clock. The guardrail "no cappuccino after noon" asks this clock for the time
 * (GET /api/clock), so the demo can switch between morning and afternoon without waiting.
 */
@ApplicationScoped
public class ShopClock {

    public enum Mode { REAL, MORNING, AFTERNOON }

    @ConfigProperty(name = "shop.timezone", defaultValue = "Europe/Brussels")
    String timezone;

    private volatile Mode mode = Mode.REAL;

    public String time() {
        return switch (mode) {
            case MORNING -> "09:30";
            case AFTERNOON -> "15:00";
            case REAL -> LocalTime.now(ZoneId.of(timezone)).format(DateTimeFormatter.ofPattern("HH:mm"));
        };
    }

    public Mode mode() {
        return mode;
    }

    public void set(Mode newMode) {
        mode = newMode == null ? Mode.REAL : newMode;
    }
}
