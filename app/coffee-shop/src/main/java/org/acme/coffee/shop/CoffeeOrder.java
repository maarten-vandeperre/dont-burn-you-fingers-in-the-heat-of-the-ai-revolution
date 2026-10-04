package org.acme.coffee.shop;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.CascadeType;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.OneToMany;
import jakarta.persistence.OrderBy;
import jakarta.persistence.Table;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;

/** coffee.orders in the inventory database: every change is captured by Debezium. */
@Entity
@Table(schema = "coffee", name = "orders")
public class CoffeeOrder extends PanacheEntityBase {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    public Long id;

    @Column(nullable = false)
    public String status;

    @Column(name = "total_cents", nullable = false)
    public int totalCents;

    @Column(nullable = false)
    public int cups;

    @Column(name = "model_alias")
    public String modelAlias;

    @Column(name = "menu_version")
    public String menuVersion;

    @Column(name = "order_text", length = 500)
    public String orderText;

    @Column(name = "created_at", insertable = false, updatable = false)
    public OffsetDateTime createdAt;

    @Column(name = "updated_at")
    public OffsetDateTime updatedAt;

    @OneToMany(mappedBy = "order", cascade = CascadeType.ALL, orphanRemoval = true, fetch = FetchType.EAGER)
    @OrderBy("id")
    public List<CoffeeOrderLine> lines = new ArrayList<>();
}
