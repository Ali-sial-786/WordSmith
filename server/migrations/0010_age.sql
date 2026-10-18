-- Players' ages (shared/age.md): the month and year they were born, asked
-- at setup (or once, for accounts made before ages were asked). Online play
-- is for 13 and over; an account that turns out to be younger is deleted,
-- so these never hold an under-13's birth date. NULL until given.
ALTER TABLE users ADD COLUMN birth_year INTEGER;
ALTER TABLE users ADD COLUMN birth_month INTEGER;
