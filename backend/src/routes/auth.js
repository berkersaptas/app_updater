import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { query } from '../db.js';
import { asyncHandler } from '../asyncHandler.js';
import { renderPage } from '../views/layout.js';

export const authRouter = Router();

authRouter.get('/register', (req, res) => {
  res.send(renderPage('Register', `
    <form method="post" action="/auth/register">
      <div><label>Email <input type="email" name="email" required></label></div>
      <div><label>Password <input type="password" name="password" required minlength="8"></label></div>
      <button type="submit">Create account</button>
    </form>
    <p class="muted">Already have an account? <a href="/auth/login">Log in</a></p>
  `));
});

authRouter.post('/register', asyncHandler(async (req, res) => {
  const { email, password } = req.body ?? {};
  if (!email || !password || password.length < 8) {
    return res.status(400).send(renderPage('Register', `<p class="error">Email and a password (8+ characters) are required.</p><p><a href="/auth/register">Back</a></p>`));
  }
  const passwordHash = await bcrypt.hash(password, 10);
  try {
    const result = await query(
      `insert into users (email, password_hash) values ($1, $2) returning id`,
      [email.toLowerCase(), passwordHash],
    );
    req.session.userId = result.rows[0].id;
    res.redirect(303, '/apps');
  } catch (error) {
    if (error.code === '23505') {
      return res.status(409).send(renderPage('Register', `<p class="error">An account with that email already exists.</p><p><a href="/auth/login">Log in</a></p>`));
    }
    throw error;
  }
}));

authRouter.get('/login', (req, res) => {
  res.send(renderPage('Login', `
    <form method="post" action="/auth/login">
      <div><label>Email <input type="email" name="email" required></label></div>
      <div><label>Password <input type="password" name="password" required></label></div>
      <button type="submit">Log in</button>
    </form>
    <p class="muted">No account yet? <a href="/auth/register">Register</a></p>
  `));
});

authRouter.post('/login', asyncHandler(async (req, res) => {
  const { email, password } = req.body ?? {};
  const result = await query('select id, password_hash from users where email = $1', [(email ?? '').toLowerCase()]);
  const user = result.rows[0];
  const valid = user && (await bcrypt.compare(password ?? '', user.password_hash));
  if (!valid) {
    return res.status(401).send(renderPage('Login', `<p class="error">Invalid email or password.</p><p><a href="/auth/login">Try again</a></p>`));
  }
  req.session.userId = user.id;
  res.redirect(303, '/apps');
}));

authRouter.post('/logout', (req, res) => {
  req.session.destroy(() => res.redirect(303, '/auth/login'));
});
