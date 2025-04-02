package testutils

import (
	"context"
	"fmt"
	"path/filepath"
	"runtime"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"github.com/rs/zerolog"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"
)

var (
	image   = "postgres:16-alpine"
	timeout = 30 * time.Second
	dbname  = "test"
	dbuser  = "test"
	dbpass  = "test"
)

type PgContainer struct {
	cfg Config
}

type PgContainerOutput struct {
	dsn string
}

type Config struct {
	migrationsPath string
	host           string
	image          string
	log            *zerolog.Logger
}

func (c *Config) WithMigrationsPath(path string) *Config {
	c.migrationsPath = path
	return c
}

func (c *Config) WithLogger(log *zerolog.Logger) *Config {
	c.log = log
	return c
}

func (c *Config) WithImage(img string) *Config {
	c.image = img
	return c
}

func NewPgContainer(cfg Config) *PgContainer {
	return &PgContainer{cfg: cfg}
}

func (p *PgContainer) Host() string {
	return p.cfg.host
}

func (p *PgContainer) setup(ctx context.Context) (*PgContainerOutput, error) {
	pgc, err := postgres.Run(
		ctx,
		p.cfg.image,
		postgres.WithDatabase(dbname),
		postgres.WithUsername(dbuser),
		postgres.WithPassword(dbpass),
		testcontainers.WithWaitStrategy(
			wait.ForLog("listening on IPv4 address").
				WithOccurrence(1).
				WithStartupTimeout(timeout),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("unable to start postgres container: %w", err)
	}

	// get container host and port
	mappedPort, err := pgc.MappedPort(ctx, "5432")
	if err != nil {
		return nil, fmt.Errorf("unable to get mapped port: %w", err)
	}

	host, err := pgc.Host(ctx)
	if err != nil {
		return nil, fmt.Errorf("unable to get container host: %w", err)
	}

	dsn := fmt.Sprintf(
		"postgres://%s:%s@%s:%s/%s?sslmode=disable",
		dbuser,
		dbpass,
		host,
		mappedPort.Port(),
		dbname,
	)

	return &PgContainerOutput{dsn: dsn}, nil
}

func (p *PgContainer) runMigrations(ctx context.Context, dns string) error {
	conn, err := pgx.Connect(ctx, dns)
	if err != nil {
		return fmt.Errorf("unable to open database connection: %w", err)
	}
	defer conn.Close(ctx)

	// ping the database to ensure it's up
	if err := conn.Ping(ctx); err != nil {
		return fmt.Errorf("unable to ping database: %w", err)
	}

	// Since goose requires a *sql.DB, we need to get one from pgx
	db := stdlib.OpenDB(*conn.Config())
	defer db.Close()

	// Get the project root directory
	projectRoot := getProjectRoot()
	migrationsDirPath := filepath.Join(projectRoot, p.cfg.migrationsPath)

	// Run migrations
	if err := goose.Up(db, migrationsDirPath); err != nil {
		return fmt.Errorf("failed to run migrations: %w", err)
	}

	return nil
}

func getProjectRoot() string {
	_, b, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(b), "..")
}
