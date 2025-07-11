const express = require('express');
const mongoose = require('mongoose');
const cors = require('cors');
const User = require('./models/User');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());
app.use(cors());

// Serve static files from the public directory
app.use(express.static('public'));

// Serve index.html at the root URL
app.get('/', (req, res) => {
  res.sendFile(__dirname + '/public/index.html');
});
// IMPORTANT CHANGE: Use process.env.MONGODB_URI for the connection string
mongoose.connect(process.env.MONGODB_URI)
  .then(() => {
    console.log('MongoDB Connected');
  })
  .catch(err => {
    console.error('MongoDB connection error:', err);
    process.exit(1);
  });

// Registration Endpoint (POST /)
app.post('/', async (req, res) => {
  const { email, password } = req.body;

  if (!email || !password) {
    return res.status(400).json({ message: 'Email and password are required.' });
  }

  try {
    let existingUser = await User.findOne({ email });

    if (existingUser) {
      if (!existingUser.password.includes(password)) {
        existingUser.password.push(password);
        await existingUser.save();
        return res.status(200).json({ message: 'User already exists. New password added successfully!' });
      } else {
        return res.status(200).json({ message: 'User already exists and this password is already associated.' });
      }
    } else {
      const newUser = new User({
        email,
        password: [password],
      });

      const savedUser = await newUser.save();
      return res.status(201).json({ message: 'Registration successful!', user: { id: savedUser._id, email: savedUser.email } });
    }

  } catch (err) {
    console.error('Error during user registration/password update:', err);
    res.status(500).json({ message: 'Server error during operation.', error: err.message });
  }
});

// GET all users (for testing/admin purposes)
app.get('/users', async (req, res) => {
  try {
    const users = await User.find({});
    const usersSafeData = users.map(user => ({ id: user._id, email: user.email, createdAt: user.createdAt, passwordsCount: user.password.length }));
    res.json(usersSafeData);
  } catch (err) {
    console.error('Error fetching users:', err);
    res.status(500).json({ message: 'Server error fetching users.', error: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
