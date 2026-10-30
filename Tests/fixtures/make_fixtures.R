# Regenerates the Parquet fixtures and expected.txt used by the footer parser tests.
# Run from the repository root: Rscript Tests/fixtures/make_fixtures.R
#
# Row counts and leaf-column counts in expected.txt come from Apache Arrow (the reference
# reader); leaf column paths follow Arrow's Parquet writer naming and are listed by hand.
suppressMessages(library(arrow))

dir <- "Tests/fixtures"
expected <- character()

record <- function(file, paths) {
  path <- file.path(dir, file)
  reader <- ParquetFileReader$create(path)
  stopifnot(reader$num_columns == length(paths))
  expected <<- c(expected, paste(file, 1, reader$num_rows, reader$num_columns,
                                 paste(paths, collapse = ","), sep = "|"))
}

flat <- arrow_table(
  id = Array$create(1:3, int32()),
  score = c(1.5, 2.5, NA),
  name = c("a", "b", NA),
  flag = c(TRUE, FALSE, NA),
  day = as.Date(c("2026-01-01", "2026-01-02", NA)),
  ts = as.POSIXct(c("2026-01-01 10:00:00", "2026-01-02 11:00:00", NA), tz = "UTC"),
  amount = Array$create(c(1.25, 2.5, NA))$cast(decimal128(10, 2))
)
write_parquet(flat, file.path(dir, "flat.parquet"))
record("flat.parquet", c("id", "score", "name", "flag", "day", "ts", "amount"))

nested <- arrow_table(
  id = 1:3,
  tags = list(c("x", "y"), character(0), "z"),
  point = StructArray$create(data.frame(x = c(1, 2, 3), y = c(4L, 5L, 6L)))
)
write_parquet(nested, file.path(dir, "nested.parquet"))
record("nested.parquet", c("id", "tags.list.element", "point.x", "point.y"))

rowgroups <- arrow_table(n = seq_len(1000L), label = rep(c("a", "b"), 500))
write_parquet(rowgroups, file.path(dir, "rowgroups.parquet"), chunk_size = 100)
record("rowgroups.parquet", c("n", "label"))

empty <- arrow_table(a = integer(0), b = character(0))
write_parquet(empty, file.path(dir, "empty.parquet"))
record("empty.parquet", c("a", "b"))

wide_names <- sprintf("col_%03d", 1:300)
wide <- arrow_table(as.data.frame(setNames(as.list(seq_along(wide_names)), wide_names)))
write_parquet(wide, file.path(dir, "wide.parquet"))
record("wide.parquet", wide_names)

# Footer details (checked in core_tests.swift by construction): 3 row groups of 4/4/2 rows,
# key/value metadata `owner`, ZSTD for `v` and SNAPPY elsewhere, and date/timestamp ranges
# spread over the row groups (overall: 1999-12-31 23:59:59 UTC to 2024-11-30).
footer <- arrow_table(
  d = as.Date(c("2024-01-15", "2023-03-01", "2024-02-01", "2023-06-30", "2024-11-30",
                "2023-12-31", "2024-05-05", "2023-04-04", "2024-07-07", "2023-08-08")),
  ts_ms = Array$create(as.POSIXct(c("2020-01-01 00:00:00.123", "2021-06-30 12:00:00", rep("2020-06-01 00:00:00", 8)),
                                  tz = "UTC"))$cast(timestamp("ms", "UTC")),
  ts_ns = Array$create(as.POSIXct(c(rep("2000-01-01 00:00:00", 9), "1999-12-31 23:59:59"), tz = "UTC"))$cast(timestamp("ns", "UTC")),
  v = Array$create(1:10, int32())
)
footer$metadata$owner <- "rkrug"
write_parquet(footer, file.path(dir, "footer.parquet"), chunk_size = 4,
              compression = c(d = "snappy", ts_ms = "snappy", ts_ns = "snappy", v = "zstd"))
record("footer.parquet", c("d", "ts_ms", "ts_ns", "v"))

# Row data (checked in core_tests.swift against the same formulas): 250 rows in row groups of
# 100, small pages, one file per codec plus PLAIN-only and INT96 variants. Row i (1-based):
#   i32 = i, i64 = i * 1e10, dbl = i * 0.25, flt = i * 0.5, flag = i even,
#   str = "row-<i>" (null when i %% 7 == 0), d = 2020-01-01 + i days (null when i %% 11 == 0),
#   ts_ms = 1577836800000 + i * 1001 ms, ts_us = 1577836800000000 + i * 1000001 us,
#   ts_ns = i * 1000000001 ns, dec = i * 1.25 (decimal(10,2)), dec38 = -i * 1.5 (decimal(38,4)),
#   bin = bytes (i %% 256, 0xab), tags = list(i, i + 1) (nested), pt = struct(x = i) (nested).
n <- 250L
i <- seq_len(n)
rows <- arrow_table(
  i32 = Array$create(i, int32()),
  i64 = Array$create(i * 1e10, int64()),
  dbl = i * 0.25,
  flt = Array$create(i * 0.5, float32()),
  flag = i %% 2L == 0L,
  str = ifelse(i %% 7L == 0L, NA, paste0("row-", i)),
  d = as.Date(ifelse(i %% 11L == 0L, NA, as.Date("2020-01-01") + i)),
  ts_ms = Array$create(1577836800000 + i * 1001, int64())$cast(timestamp("ms", "UTC")),
  ts_us = Array$create(1577836800000000 + i * 1000001, int64())$cast(timestamp("us", "UTC")),
  ts_ns = Array$create(i * 1000000001, int64())$cast(timestamp("ns", "UTC")),
  dec = Array$create(i * 1.25)$cast(decimal128(10, 2)),
  dec38 = Array$create(-i * 1.5)$cast(decimal128(38, 4)),
  bin = Array$create(lapply(i, function(k) as.raw(c(k %% 256L, 0xab))), binary()),
  tags = lapply(i, function(k) c(k, k + 1L)),
  pt = StructArray$create(data.frame(x = i))
)
for (codec in c("snappy", "gzip", "zstd", "lz4", "uncompressed")) {
  write_parquet(rows, file.path(dir, paste0("rows_", codec, ".parquet")),
                chunk_size = 100, compression = codec, data_page_size = 512)
}
write_parquet(rows, file.path(dir, "rows_plain.parquet"), chunk_size = 100,
              compression = "snappy", use_dictionary = FALSE, data_page_size = 512)
rows_int96 <- arrow_table(ts = Array$create(1577836800000000 + i * 1000001, int64())$cast(timestamp("us", "UTC")))
write_parquet(rows_int96, file.path(dir, "rows_int96.parquet"), chunk_size = 100,
              use_deprecated_int96_timestamps = TRUE)

# Nested values (checked in core_tests.swift as JSON): 7 rows in row groups of 3, 3, 1 with
# empty and null lists, nulls inside lists, lists of structs, maps, a nested struct and
# lists of lists.
nested_rows <- arrow_table(
  id = Array$create(1:7, int32()),
  l_str = Array$create(list(c("a", "b"), character(0), NULL, c("c", NA), "d", NULL, c("e", "f", "g")),
                       type = list_of(utf8())),
  l_struct = Array$create(list(
    data.frame(a = 1L, b = "x"), data.frame(a = integer(0), b = character(0)), NULL,
    data.frame(a = c(2L, NA), b = c("y", "z")), data.frame(a = 3L, b = NA_character_), NULL,
    data.frame(a = 4L, b = "w")
  ), type = list_of(struct(a = int32(), b = utf8()))),
  m = Array$create(list(
    data.frame(key = c("a", "b"), value = c(1L, 2L)), data.frame(key = character(0), value = integer(0)), NULL,
    data.frame(key = "c", value = NA_integer_), data.frame(key = "d", value = 4L), NULL,
    data.frame(key = c("e", "f"), value = c(5L, 6L))
  ), type = map_of(utf8(), int32())),
  s = StructArray$create(data.frame(x = c(1L, 2L, NA, 4L, 5L, 6L, 7L),
                                    inner = I(data.frame(y = c("p", NA, "q", "r", "s", "t", "u"))))),
  ll = Array$create(list(list(c(1L, 2L), 3L), list(), NULL, list(integer(0)), list(4L, NULL), NULL, list(5:6)),
                    type = list_of(list_of(int32())))
)
write_parquet(nested_rows, file.path(dir, "nested_rows.parquet"), chunk_size = 3)
record("nested_rows.parquet", c("id", "l_str.list.element", "l_struct.list.element.a", "l_struct.list.element.b",
                                "m.key_value.key", "m.key_value.value", "s.x", "s.inner.y",
                                "ll.list.element.list.element"))

# Not a Parquet file: the trailer of a cut-off file is missing.
bytes <- readBin(file.path(dir, "flat.parquet"), "raw", n = 64)
writeBin(bytes, file.path(dir, "truncated.parquet"))
expected <- c(expected, "truncated.parquet|0|0|0|")

writeLines(c("# file|valid|rows|leaf_columns|leaf_paths (generated by make_fixtures.R)", expected),
           file.path(dir, "expected.txt"))
