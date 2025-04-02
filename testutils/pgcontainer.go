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

const (
	defaultImage  = "postgres:16-alpine"
	defaultDbName = "test"
	defaultDbUser = "test"
	defaultDbPass = "test"
)

var defaultTimeout = 30 * time.Second

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
	dbName         string
	dbUser         string
	dbPass         string
	timeout        time.Duration
}

// NewConfig creates a new Config with default values
func NewConfig() Config {
	return Config{
		image:   defaultImage,
		timeout: defaultTimeout,
		dbName:  defaultDbName,
		dbUser:  defaultDbUser,
		dbPass:  defaultDbPass,
	}
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
		postgres.WithDatabase(p.cfg.dbName),
		postgres.WithUsername(p.cfg.dbUser),
		postgres.WithPassword(p.cfg.dbPass),
		testcontainers.WithWaitStrategy(
			wait.ForLog("listening on IPv4 address").
				WithOccurrence(1).
				WithStartupTimeout(p.cfg.timeout),
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
		p.cfg.dbUser,
		p.cfg.dbPass,
		host,
		mappedPort.Port(),
		p.cfg.dbName,
	)

	return &PgContainerOutput{dsn: dsn}, nil
}

func (p *PgContainer) migrate(ctx context.Context, dns string) error {
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
